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
            pageCount: crops.count, loadPage: { crops[$0] }, recognizer: VisionReadVariation(markSecondPage: true)
        )
        XCTAssertFalse(result.needsOverlapReview, "Both seams must be registered; the marked readings cannot align")
        let recognized = result.text.components(separatedBy: "\n").map { line in
            line.uppercased().replacingOccurrences(of: " \(VisionReadVariation.marker)", with: "")
                .replacingOccurrences(of: ",", with: ".")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let expected = Set(rows)
        let recovered = recognized.filter(expected.contains)
        XCTAssertGreaterThanOrEqual(recovered.count, 38, "Recognized \(recognized.count) lines: \(recognized)")
        XCTAssertLessThanOrEqual(recognized.count, rows.count)
        XCTAssertEqual(recognized.filter { $0 == drink }.count, 2)
        var remaining = rows[...]
        for row in recovered {
            guard let index = remaining.firstIndex(of: row) else {
                XCTFail("Unexpected duplicate or out-of-order row: \(row)")
                return
            }
            remaining = remaining.suffix(from: remaining.index(after: index))
        }
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
        XCTAssertFalse(result.needsOverlapReview)
        let recognized = result.text.uppercased().replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: "\n")
        XCTAssertEqual(recognized.filter { $0 == "OATS 35.95" }.count, 1)
    }

    @MainActor
    func testRegistrationRejectsNearbyOffsetsThatExplainPeriodicBoxes() async throws {
        let rows = (0..<28).map { "ITEM \($0 + 20).95" }
        let receipt = try renderReceipt(rows)
        let crops = try [0, 12].map { try crop(receipt, beginningAt: $0) }
        let first = (0..<16).map { "TOP \($0 + 20).95" }
        let second = (0..<16).map { "BOTTOM \($0 + 32).95" }
        let recognizer = SequentialReadings([first, second])
        let result = try await ReceiptPhotoRecognition.read(
            pageCount: crops.count, loadPage: { crops[$0] }, recognizer: recognizer
        )
        XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
        XCTAssertTrue(result.needsOverlapReview)
    }

    @MainActor
    func testFailedRegistrationFallsBackToLongestPricedRunAndKeepsRepeatedRows() async throws {
        let first = ["SHOP", "APPLE 1.25", "RICE 3.50", "DRINK 9.95", "DRINK 9.95"]
        let second = ["apple  1,25", "RICE 3.50", "DRINK 9.95", "DRINK 9.95", "DRINK 9.95", "TOTAL 34.60"]
        let result = try await readBlankPhotos([first, second])
        XCTAssertEqual(result.text, (first + Array(second.suffix(2))).joined(separator: "\n"))
        XCTAssertFalse(result.needsOverlapReview)
    }

    @MainActor
    func testAmountOrTaxClassMismatchKeepsAllLinesAndAsksForReview() async throws {
        let first = ["APPLES 1.30", "RICE 2.40 A", "BREAD 3.50"]
        for differentRice in ["RICE 2.41 A", "RICE 2.40 B"] {
            let second = ["APPLES 1.30", differentRice, "BREAD 3.50"]
            let result = try await readBlankPhotos([first, second])
            XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
            XCTAssertTrue(result.needsOverlapReview)
        }
    }

    @MainActor
    func testTwoMatchingRowsAreNeverRemoved() async throws {
        let first = ["BREAD 1.00", "RICE 2.00", "MILK 3.00"]
        let second = ["RICE 2.00", "MILK 3.00", "HAM 4.00"]
        let result = try await readBlankPhotos([first, second])
        XCTAssertEqual(result.text, (first + second).joined(separator: "\n"))
        XCTAssertTrue(result.needsOverlapReview)
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
            XCTAssertTrue(result.needsOverlapReview)
        }
    }

    @MainActor
    func testSinglePhotoKeepsExactOrderingAndText() async throws {
        let first = ["SHOP", "DRINK 9.95", "DRINK 9.95", "SUMA PLN 19.90"]
        let result = try await readBlankPhotos([first])
        XCTAssertEqual(result.text, first.joined(separator: "\n"))
        XCTAssertFalse(result.needsOverlapReview)
    }

    private static let linePitch = 52
    private static let pageRows = 16

    private actor VisionReadVariation: ReceiptTextRecognizing {
        static let marker = "ZTESTMARK"
        private var pageIndex = 0
        private let markSecondPage: Bool
        private let skipSecondPageRow: Int?

        init(markSecondPage: Bool = false, skipSecondPageRow: Int? = nil) {
            self.markSecondPage = markSecondPage
            self.skipSecondPageRow = skipSecondPageRow
        }

        func recognize(_ image: CGImage) async throws -> [TextFragment] {
            let second = pageIndex == 1
            pageIndex += 1
            let fragments = try await VisionReceiptRecognizer().recognize(image)
            guard second else { return fragments }
            if let row = skipSecondPageRow {
                let fromTop = CGFloat(row) / CGFloat(ReceiptMultiPhotoVisionTests.pageRows)
                let toBottom = CGFloat(row + 1) / CGFloat(ReceiptMultiPhotoVisionTests.pageRows)
                return fragments.filter { !(fromTop..<toBottom).contains(1 - $0.box.midY) }
            }
            guard markSecondPage else { return fragments }
            // Keep real Vision boxes but rule out a text match between pages.
            return fragments.map { TextFragment(text: "\($0.text) \(Self.marker)", box: $0.box, rowSlope: $0.rowSlope) }
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
            pageCount: pages.count, loadPage: { _ in image }, recognizer: SequentialReadings(pages)
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
