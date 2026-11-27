import CoreGraphics
import XCTest
@testable import Vesta

final class ReceiptOCRSeamTests: XCTestCase {
    private let imageHeight = 385

    func testCoalescesStraddlingCopiesAtStripCut() {
        // Both observations are on their own sides of the cut. Their texts
        // disagree, and the observation farther from the cut should win.
        let merged = merge(upper: [("FIRST READ", -2)], lower: [("SECOND READ", 1)])
        XCTAssertEqual(merged.map(\.text), ["FIRST READ"])
    }

    func testRecoversCopiesOnWrongSidesOfStripCut() {
        // Each observation is on the side assigned to the other strip.
        let merged = merge(upper: [("FIRST READ", 1)], lower: [("SECOND READ", -2)])
        XCTAssertEqual(merged.map(\.text), ["SECOND READ"])
    }

    func testKeepsAdjacentIdenticalPurchasesAtStripCut() {
        let drink = "DRINK XY 250ml 9,00"
        // These adjacent boxes have no vertical overlap. Both observations
        // are on the side assigned to the other strip, and each is unique.
        let merged = merge(upper: [(drink, 4)], lower: [(drink, -4)], lineHeight: 8)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(ReceiptLineOrdering.lines(from: merged), [drink, drink])
    }

    func testMatchesCopyJustOutsideStripCutBand() {
        // The upper observation is just outside the six-row half-band. It
        // still overlaps the observation the lower strip reads inside it.
        let merged = merge(upper: [("FIRST READ", -7)], lower: [("SECOND READ", -4)])
        XCTAssertEqual(merged.map(\.text), ["FIRST READ"])
    }

    func testPlansSixAbuttingStripsJustAboveTilingThreshold() throws {
        let strips = ReceiptOCRStrip.plan(width: 128, height: imageHeight)
        XCTAssertEqual(strips.count, 6)
        XCTAssertEqual(try XCTUnwrap(strips.first).ownedRows.lowerBound, 0)
        let last = try XCTUnwrap(strips.last)
        XCTAssertEqual(last.rows.upperBound, imageHeight)
        XCTAssertEqual(last.ownedRows.upperBound, CGFloat(imageHeight))
        for (upper, lower) in zip(strips, strips.dropFirst()) {
            XCTAssertEqual(upper.rows.upperBound - lower.rows.lowerBound, 24)
            XCTAssertEqual(upper.ownedRows.upperBound, lower.ownedRows.lowerBound)
            XCTAssertEqual(upper.ownedRows.upperBound, CGFloat(upper.rows.upperBound + lower.rows.lowerBound) / 2)
        }
    }

    private func merge(
        upper: [(text: String, offset: CGFloat)], lower: [(text: String, offset: CGFloat)], lineHeight: CGFloat = 12
    ) -> [TextFragment] {
        let strips = ReceiptOCRStrip.plan(width: 128, height: imageHeight)
        let cut = strips[0].ownedRows.upperBound
        var observations = Array(repeating: [TextFragment](), count: strips.count)
        for (index, samples) in [upper, lower].enumerated() {
            let strip = strips[index]
            let stripHeight = CGFloat(strip.rows.count)
            observations[index] = samples.map { sample in
                let localY = (CGFloat(strip.rows.upperBound) - cut - sample.offset - lineHeight / 2) / stripHeight
                let local = TextFragment(
                    text: sample.text, box: CGRect(x: 0.15, y: localY, width: 0.5, height: lineHeight / stripHeight)
                )
                return strip.map(local, toImageHeight: imageHeight)
            }
        }
        return ReceiptOCRStrip.merge(observations, strips: strips, imageHeight: imageHeight)
    }
}
