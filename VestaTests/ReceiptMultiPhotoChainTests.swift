import CoreGraphics
import XCTest
@testable import Vesta

@MainActor
final class ReceiptMultiPhotoChainTests: XCTestCase {
    func testGeometryAfterTextAlignmentDoesNotRepeatTheConsumedPrefix() async throws {
        let result = try await recognizeChain()

        XCTAssertEqual(result.text, (["SHOP"] + middle + tail).joined(separator: "\n"))
        XCTAssertEqual(result.overlapReview, .textAlignment)
    }

    func testGeometryAfterTextAlignmentKeepsAnUnmatchedRowInTheConsumedPrefix() async throws {
        let addedLine = "SPECIAL PURCHASE 5.55"
        let result = try await recognizeChain(replacingFirstLowerRowWith: addedLine)
        let appended = [addedLine] + middle.suffix(4) + tail

        XCTAssertEqual(result.text, (["SHOP"] + middle + appended).joined(separator: "\n"))
        XCTAssertEqual(result.overlapReview, .uncertain)
    }

    private let middle = [
        "APPLES 1.10", "BREAD 2.10", "COFFEE 3.10", "DATES 4.10", "EGGS 5.10",
        "FLOUR 6.10", "GRAPES 7.10", "LOYALTY", "ICE 9.10", "JAM 10.10",
    ]
    private let tail = ["KALE 11.10", "LIME 12.10", "MINT 13.10", "NUTS 14.10", "TOTAL 105.30"]

    private func recognizeChain(replacingFirstLowerRowWith replacement: String? = nil) async throws
        -> ReceiptPhotoRecognition.Result {
        let upper = ["SHOP"] + middle.prefix(7)
        var lower = Array(middle.suffix(5)) + tail
        if let replacement { lower[0] = replacement }
        let readings = [fragments(upper), fragments(middle), fragments(lower, offset: 5)]
        let pages = try [900, 800, 800].map(makeImage(height:))
        return try await ReceiptPhotoRecognition.read(
            pageCount: pages.count, loadPage: { pages[$0] }, recognizer: ChainReadings(readings),
            translate: { upper, lower in
                // The middle photo's first seven rows have already been emitted
                // by text alignment. The next overlap includes two of them.
                guard upper.height == 800, lower.height == 800 else { return nil }
                return CGAffineTransform(translationX: 0, y: -400)
            }
        )
    }

    private func fragments(_ rows: [String], offset: Int = 0) -> [TextFragment] {
        rows.enumerated().map { index, text in
            let lane = CGFloat((index + offset) % 10)
            return TextFragment(text: text, box: CGRect(
                x: 0.05 + lane * 0.09, y: 0.93 - CGFloat(index) / 10, width: 0.06, height: 0.03
            ))
        }
    }

    private func makeImage(height: Int) throws -> CGImage {
        let width = 144
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}

private actor ChainReadings: ReceiptTextRecognizing {
    private var pages: ArraySlice<[TextFragment]>

    init(_ pages: [[TextFragment]]) { self.pages = pages[...] }

    func recognize(_: CGImage) async throws -> [TextFragment] { pages.removeFirst() }
}
