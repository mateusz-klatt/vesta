import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import Vesta

final class ReceiptTiledVisionTests: XCTestCase {
    @MainActor
    func testRecoversNearlyAllRowsOfAnEightyLineReceipt() async throws {
        try await assertRecognizesReceipt(lineCount: 80)
    }

    @MainActor
    func testRecoversNearlyAllRowsOfAOneHundredSixtyLineReceipt() async throws {
        try await assertRecognizesReceipt(lineCount: 160)
    }

    @MainActor
    private func assertRecognizesReceipt(lineCount: Int) async throws {
        let products = ["APPLES", "BREAD", "YOGURT", "COFFEE", "ORANGES", "BUTTER", "BANANAS", "CHEESE"]
        let rows = (0..<lineCount).map { index in
            (name: products[index % products.count], price: "\(10 + index).95")
        }
        let image = try renderReceipt(rows)
        let fragments = try await VisionReceiptRecognizer().recognize(image)
        let lines = ReceiptLineOrdering.lines(from: fragments)
        let expectedIndexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { index, row in
            ("\(row.name) \(row.price)", index)
        })
        let recognizedIndexes = lines.compactMap { line in
            let normalized = line.uppercased().replacingOccurrences(of: ",", with: ".")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return expectedIndexes[normalized]
        }

        let minimum = (lineCount * 95 + 99) / 100
        XCTAssertGreaterThanOrEqual(Set(recognizedIndexes).count, minimum, "Recognized \(lines.count) lines")
        XCTAssertEqual(recognizedIndexes, Set(recognizedIndexes).sorted(), "Recognized rows must stay unique and ordered")
    }

    private func renderReceipt(_ rows: [(name: String, price: String)]) throws -> CGImage {
        let width = 576
        let linePitch = 52
        let height = (rows.count + 1) * linePitch
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 35, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]

        for (index, row) in rows.enumerated() {
            let baseline = CGFloat(height - (index + 1) * linePitch)
            let name = CTLineCreateWithAttributedString(NSAttributedString(string: row.name, attributes: attributes))
            let price = CTLineCreateWithAttributedString(NSAttributedString(string: row.price, attributes: attributes))
            let priceWidth = CTLineGetTypographicBounds(price, nil, nil, nil)
            context.textPosition = CGPoint(x: 28, y: baseline)
            CTLineDraw(name, context)
            context.textPosition = CGPoint(x: CGFloat(width - 28) - priceWidth, y: baseline)
            CTLineDraw(price, context)
        }
        return try XCTUnwrap(context.makeImage())
    }
}
