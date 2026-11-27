import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import Vesta

final class ReceiptMultiPhotoVisionTests: XCTestCase {
    @MainActor
    func testVisionRegistersThreeOverlappingPhotosAndKeepsBothDrinks() async throws {
        let drink = "DRINK 9.95"
        var rows = sampleRows(count: 40)
        rows[13] = drink
        rows[14] = drink
        let fullReceipt = try renderReceipt(rows)
        let crops = try [0, 12, 24].map { try crop(fullReceipt, beginningAt: $0) }
        let result = try await ReceiptPhotoRecognition.read(
            pageCount: crops.count, loadPage: { crops[$0] }, recognizer: VisionReceiptRecognizer()
        )
        let recognized = normalizedOutput(result)
        let expected = Set(rows)
        let recovered = recognized.filter(expected.contains)
        XCTAssertGreaterThanOrEqual(recovered.count, rows.count - 2, "Recognized \(recognized.count) lines: \(recognized)")
        XCTAssertLessThanOrEqual(recognized.count, rows.count)
        XCTAssertEqual(recognized.filter { $0 == drink }.count, 2)
        // Remove only missing expected lines. Compare the entire remaining
        // order, including both copies of the identical purchase.
        XCTAssertEqual(recovered, rows.filter(Set(recovered).contains))
        XCTAssertNil(result.overlapReview, "Text alignment cannot resolve the repeated purchases")
    }

    @MainActor
    func testRegisteredSeamPreservesRowMissedByItsOwningPhoto() async throws {
        var rows = sampleRows(count: 26)
        rows[15] = "OATS 35.95"
        let receipt = try renderReceipt(rows)
        let crops = try [0, 10].map { try crop(receipt, beginningAt: $0) }
        let result = try await ReceiptPhotoRecognition.read(
            pageCount: crops.count, loadPage: { crops[$0] }, recognizer: VisionReadVariation(skipSecondPageRow: 5)
        )
        XCTAssertEqual(result.overlapReview, .uncertain)
        XCTAssertEqual(normalizedOutput(result), rows)
    }

    @MainActor
    func testMixedRepeatedTextRunKeepsAllPurchasesAndRequestsReview() async throws {
        let repeated = ["DRINK 9.95", "DRINK 9.95", "RICE 3.50"]
        let first = ["SHOP"] + repeated
        let second = repeated + ["TOTAL 46.80"]
        let result = try await readBlankPhotos([first, second])
        XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
        XCTAssertEqual(result.overlapReview, .uncertain)
    }

    @MainActor
    func testUniqueThreeLineAlignmentDropsRunOnceAndRequestsSoftReview() async throws {
        let first = ["SHOP", "APPLE 1.25", "RICE 3.50", "DRINK 9.95"]
        let second = ["apple  1,25", "RICE 3.50", "DRINK 9.95", "TOTAL 14.70"]
        let result = try await readBlankPhotos([first, second])
        XCTAssertEqual(result.text, (first + Array(second.suffix(1))).joined(separator: "\n"))
        XCTAssertEqual(result.overlapReview, .textAlignment)
    }

    @MainActor
    func testUniqueBoundaryRunAlsoAppearingInsideEitherPhotoIsPreserved() async throws {
        let run = ["APPLE 1.25", "RICE 3.50", "DRINK 9.95"]
        for (first, second) in [(run + ["SHOP"] + run, run + ["TOTAL"]),
                                (["SHOP"] + run, run + ["SUBTOTAL"] + run)] {
            let result = try await readBlankPhotos([first, second])
            XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
            XCTAssertEqual(result.overlapReview, .uncertain)
        }
    }

    @MainActor
    func testPeriodicAliasesOutsideEitherOverlapLimitAreEvaluated() async throws {
        // The true shift produces, respectively, 61% or 8% overlap.
        // A one-pitch error is inside the supported range and has plausible
        // box matches. Further offsets are weaker because the column drifts.
        for (overlap, pitch, offset, count) in [(0.61, 0.06, -1, 10), (0.08, 0.04, 1, 3)] {
            let upper = (0..<count).map { index in
                fragment("FIRST \(index)", y: 0.02 + CGFloat(index) * pitch, x: 0.1 + CGFloat(index) * 0.04,
                         width: 0.18, height: 0.02)
            }
            let lower = upper.map {
                TextFragment(text: $0.text.replacingOccurrences(of: "FIRST", with: "SECOND"),
                             box: $0.box.offsetBy(dx: 0, dy: 1 - overlap))
            }
            // For the shallow overlap, the off-by-one candidate sees the
            // additional top row, which cannot participate in the true alias.
            let observedLower = lower.filter { $0.box.maxY <= 1 } + (overlap < 0.1
                ? [fragment("SECOND EXTRA", y: 0.90, x: 0.06, width: 0.18, height: 0.02)] : [])
            let shift = (overlap + CGFloat(offset) * pitch - 1) * 1_000
            let probe = TranslationProbe(CGAffineTransform(translationX: 0, y: shift))
            let result = try await readFragments([upper, observedLower], translate: probe.translate)
            XCTAssertEqual(probe.dimensions.count, 1, "Candidate must reach registration at \(overlap)")
            let unmerged = [upper, observedLower].flatMap { rows in rows.sorted { $0.box.midY > $1.box.midY }.map(\.text) }
            XCTAssertEqual(result.text, unmerged.joined(separator: "\n"), "Unsafe candidate at \(overlap)")
            XCTAssertEqual(result.overlapReview, .uncertain)
        }
    }

    func testPitchUsesWholeRowGapsWhenNameAndPriceSplit() throws {
        let lines = [0.8, 0.74, 0.68, 0.62].flatMap { y in
            [fragment("NAME", y: y, height: 0.03), fragment("PRICE", y: y - 0.02, height: 0.03)]
        }
        XCTAssertEqual(try XCTUnwrap(ReceiptPhotoRecognition.rowPitch(lines)), 0.06, accuracy: 0.0001)
    }

    func testPitchIncludesGapsBetweenSlightlyOverlappingRows() throws {
        let lines = [0.8, 0.76, 0.72, 0.68].map { fragment("ITEM", y: $0, height: 0.042) }
        XCTAssertEqual(try XCTUnwrap(ReceiptPhotoRecognition.rowPitch(lines)), 0.04, accuracy: 0.0001)
    }

    @MainActor
    func testRegisteredSeamKeepsDifferentTextWithTheSameBoxInOrder() async throws {
        let rows = sampleRows(count: 16)
        let upper = geometricRows(rows[0..<10])
        var lower = geometricRows(rows[6..<16])
        lower[2] = TextFragment(text: "DIFFERENT PURCHASE 4.99", box: lower[2].box)
        let result = try await readFragments([upper, lower], translate: { _, _ in
            CGAffineTransform(translationX: 0, y: -600)
        })
        var expected = rows
        expected.insert(lower[2].text, at: 9)
        XCTAssertEqual(normalizedOutput(result), expected)
        XCTAssertEqual(result.overlapReview, .uncertain)
    }

    @MainActor
    func testUnequalHeightPreviewsUseOneGridAndKeepTheExactRows() async throws {
        let rows = sampleRows(count: 19)
        let upper = geometricRows(rows[0..<10])
        let lower = geometricRows(rows[6..<19], pageHeight: 1_300)
        let probe = TranslationProbe(CGAffineTransform(translationX: 0, y: -600))
        let result = try await readFragments([upper, lower], heights: [1_000, 1_300], translate: probe.translate)
        let common = CGSize(width: 300, height: 1_300)
        XCTAssertEqual(probe.dimensions, [[common, common]])
        XCTAssertEqual(normalizedOutput(result), rows)
        XCTAssertNil(result.overlapReview)
    }

    @MainActor
    func testCloserPhotoRefusesRegistrationAndUsesTextReview() async throws {
        let rows = sampleRows(count: 16)
        let upper = geometricRows(rows[0..<10])
        let lower = geometricRows(rows[6..<16]).map { row in
            TextFragment(text: row.text, box: row.box.insetBy(dx: 0, dy: -row.box.height * 0.15))
        }
        let probe = TranslationProbe(CGAffineTransform(translationX: 0, y: -600))
        let result = try await readFragments([upper, lower], translate: probe.translate)
        XCTAssertEqual(probe.dimensions.count, 1)
        XCTAssertEqual(normalizedOutput(result), rows)
        XCTAssertEqual(result.overlapReview, .textAlignment)
    }

    @MainActor
    func testAmountOrTaxClassMismatchKeepsAllLinesAndAsksForReview() async throws {
        let first = ["APPLES 1.30", "RICE 2.40 A", "BREAD 3.50"]
        for differentRice in ["RICE 2.41 A", "RICE 2.40 B"] {
            let second = ["APPLES 1.30", differentRice, "BREAD 3.50"]
            let result = try await readBlankPhotos([first, second])
            XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
            XCTAssertEqual(result.overlapReview, .uncertain)
        }
    }

    @MainActor
    func testTwoMatchingRowsAreNeverRemoved() async throws {
        let first = ["BREAD 1.00", "RICE 2.00", "MILK 3.00"]
        let second = ["RICE 2.00", "MILK 3.00", "HAM 4.00"]
        let result = try await readBlankPhotos([first, second])
        XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
        XCTAssertEqual(result.overlapReview, .uncertain)
    }

    @MainActor
    func testRepeatOnlyOrAmbiguousPeriodicRunsAreNeverRemoved() async throws {
        let sequences = [Array(repeating: "DRINK 9.95", count: 4),
                         ["DRINK 9.95", "RICE 2.00", "HAM 3.00", "DRINK 9.95", "RICE 2.00", "HAM 3.00"]]
        for repeated in sequences {
            let first = ["SHOP"] + repeated
            let second = repeated + ["THANK YOU"]
            let result = try await readBlankPhotos([first, second])
            XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
            XCTAssertEqual(result.overlapReview, .uncertain)
        }
    }

    @MainActor
    func testSinglePhotoKeepsExactOrderingAndText() async throws {
        let first = ["SHOP", "DRINK 9.95", "DRINK 9.95", "SUMA PLN 19.90"]
        let result = try await readBlankPhotos([first])
        XCTAssertEqual(result.text, first.joined(separator: "\n"))
        XCTAssertNil(result.overlapReview)
    }

    private static let linePitch = 52
    private static let pageRows = 16

    private actor VisionReadVariation: ReceiptTextRecognizing {
        private var pageIndex = 0
        let skipSecondPageRow: Int

        init(skipSecondPageRow: Int) { self.skipSecondPageRow = skipSecondPageRow }

        func recognize(_ image: CGImage) async throws -> [TextFragment] {
            let second = pageIndex == 1
            pageIndex += 1
            let fragments = try await VisionReceiptRecognizer().recognize(image)
            guard second else { return fragments }
            let fromTop = CGFloat(skipSecondPageRow) / CGFloat(ReceiptMultiPhotoVisionTests.pageRows)
            let toBottom = CGFloat(skipSecondPageRow + 1) / CGFloat(ReceiptMultiPhotoVisionTests.pageRows)
            return fragments.filter { !(fromTop..<toBottom).contains(1 - $0.box.midY) }
        }
    }

    private final class TranslationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[CGSize]] = []
        let transform: CGAffineTransform

        init(_ transform: CGAffineTransform) { self.transform = transform }

        var dimensions: [[CGSize]] { lock.withLock { seen } }

        func translate(_ upper: CGImage, _ lower: CGImage) -> CGAffineTransform {
            lock.withLock {
                seen.append([upper, lower].map { CGSize(width: $0.width, height: $0.height) })
            }
            return transform
        }
    }

    private actor FragmentReadings: ReceiptTextRecognizing {
        private var pages: ArraySlice<[TextFragment]>

        init(_ pages: [[TextFragment]]) { self.pages = pages[...] }

        func recognize(_ image: CGImage) async throws -> [TextFragment] { pages.removeFirst() }
    }

    @MainActor
    private func readFragments(
        _ pages: [[TextFragment]], heights: [Int] = [1_000, 1_000],
        translate: ReceiptPhotoRecognition.Translation
    ) async throws -> ReceiptPhotoRecognition.Result {
        let images = try heights.map { height in
            try XCTUnwrap(grayContext(width: 300, height: height).makeImage())
        }
        return try await ReceiptPhotoRecognition.read(
            pageCount: pages.count, loadPage: { images[$0] }, recognizer: FragmentReadings(pages), translate: translate
        )
    }

    private func geometricRows(_ rows: ArraySlice<String>, pageHeight: CGFloat = 1_000) -> [TextFragment] {
        rows.enumerated().map { index, row in
            let y = 1 - CGFloat(index * 100 + 50) / pageHeight
            let absolute = rows.startIndex + index
            return fragment(row, y: y, x: 0.1 + CGFloat(absolute % 4) * 0.09, width: 0.15, height: 25 / pageHeight)
        }
    }

    private func fragment(_ text: String, y: CGFloat, x: CGFloat = 0.1, width: CGFloat = 0.2,
                          height: CGFloat) -> TextFragment {
        TextFragment(text: text, box: CGRect(x: x, y: y - height / 2, width: width, height: height))
    }

    private func normalizedOutput(_ result: ReceiptPhotoRecognition.Result) -> [String] {
        result.text.components(separatedBy: "\n").map { line in
            line.uppercased().replacingOccurrences(of: ",", with: ".")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    private actor SequentialReadings: ReceiptTextRecognizing {
        private var pages: ArraySlice<[String]>

        init(_ pages: [[String]]) { self.pages = pages[...] }

        func recognize(_ image: CGImage) async throws -> [TextFragment] {
            pages.removeFirst().enumerated().map { index, text in
                let center = 1 - CGFloat(index * ReceiptMultiPhotoVisionTests.linePitch + 25) / CGFloat(image.height)
                return TextFragment(text: text, box: CGRect(x: 0.1, y: center - 0.012, width: 0.2, height: 0.024))
            }
        }
    }

    @MainActor
    private func readBlankPhotos(_ pages: [[String]]) async throws -> ReceiptPhotoRecognition.Result {
        let context = try grayContext(width: 64, height: Self.linePitch * Self.pageRows)
        let image = try XCTUnwrap(context.makeImage())
        return try await ReceiptPhotoRecognition.read(
            pageCount: pages.count, loadPage: { _ in image }, recognizer: SequentialReadings(pages), translate: { _, _ in nil }
        )
    }

    private func crop(_ receipt: CGImage, beginningAt row: Int) throws -> CGImage {
        try XCTUnwrap(receipt.cropping(to: CGRect(
            x: 0, y: row * Self.linePitch, width: receipt.width, height: Self.pageRows * Self.linePitch
        )))
    }

    private func sampleRows(count: Int) -> [String] {
        let names = ["APPLES", "HAM", "WATERMELON", "MILK", "OAT BISCUITS", "BREAD", "BUTTER", "RICE", "COFFEE"]
        return (0..<count).map { "\(names[$0 % names.count]) \($0 + 20).95" }
    }

    private func renderReceipt(_ rows: [String]) throws -> CGImage {
        let width = 576
        let height = rows.count * Self.linePitch
        let context = try grayContext(width: width, height: height)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo-Bold" as CFString, 37, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        for (index, row) in rows.enumerated() {
            let baseline = CGFloat(height - index * Self.linePitch - 39)
            let separator = try XCTUnwrap(row.lastIndex(of: " "))
            let name = CTLineCreateWithAttributedString(NSAttributedString(string: String(row[..<separator]), attributes: attributes))
            let price = CTLineCreateWithAttributedString(NSAttributedString(string: String(row.suffix(from: row.index(after: separator))), attributes: attributes))
            context.textPosition = CGPoint(x: 28, y: baseline)
            CTLineDraw(name, context)
            context.textPosition = CGPoint(x: CGFloat(width - 28) - CTLineGetTypographicBounds(price, nil, nil, nil), y: baseline)
            CTLineDraw(price, context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func grayContext(width: Int, height: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
