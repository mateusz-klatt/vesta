import CoreGraphics
import XCTest
@testable import Vesta

final class ReceiptCurvedFitSafetyTests: XCTestCase {
    func testStraightTallFragmentsKeepTheirExistingPricePairs() {
        let names = ["MLEKO", "SER", "CHLEB", "SOK", "WODA"]
        let prices = ["11,00 A", "12,00 A", "13,00 A", "14,00 A", "15,00 A"]
        let centers: [CGFloat] = [0.90, 0.86, 0.82, 0.78, 0.74]
        var observedPriceCenters = centers
        // OCR jitter exceeds the former fit cap and still belongs to this band.
        observedPriceCenters[2] += 0.013
        let fragments = columns(
            names: names, nameCenters: centers, prices: prices, priceCenters: observedPriceCenters, height: 0.032
        )

        XCTAssertEqual(ReceiptLineOrdering.lines(from: fragments), pairedRows(names, prices))
    }

    func testFormerFitCapCannotShiftTheEntirePriceColumn() {
        let names = [
            "MLEKO", "SER", "CHLEB", "RYŻ", "SOK", "WODA", "MASŁO", "MĄKA", "MAKARON", "SÓL", "CUKIER", "KAWA",
            "DZIĘKUJEMY",
        ]
        let prices = (11...22).map { "\($0),00 A" }
        let centers: [CGFloat] = [0.92, 0.865, 0.81, 0.755, 0.714, 0.659, 0.604, 0.549, 0.4975, 0.4495, 0.405, 0.364, 0.3265]
        // Every price sits 0.055 above the next name, making the shifted
        // column a perfect fit. In the true column, RYŻ has a residual of
        // 0.014, within the 0.015 band tolerance but above the old 0.012 cap.
        // A gentle rise at the bottom leaves only the final price detached.
        let fragments = columns(
            names: names, nameCenters: centers, prices: prices,
            priceCenters: centers.dropFirst().map { $0 + 0.055 }, height: 0.030
        )

        let correctlyPaired = pairedRows(names, prices) + ["DZIĘKUJEMY"]
        var fallback = correctlyPaired
        fallback.replaceSubrange(11...11, with: ["22,00 A", "KAWA"])
        let actual = ReceiptLineOrdering.lines(from: fragments)
        XCTAssertTrue(actual == correctlyPaired || actual == fallback, "Unexpected price reassignment in \(actual)")
    }

    func testOutlierPriceLeavesTheLegacyBandsInPlace() {
        let names = ["MLEKO", "SER", "CHLEB", "SOK", "WODA", "MASŁO"]
        let prices = ["11,00 A", "12,00 A", "13,00 A", "14,00 A", "15,00 A", "16,00 A"]
        // Uneven spacing distinguishes the coherent tilt from a one-row shift.
        let centers: [CGFloat] = [0.91, 0.85, 0.755, 0.684, 0.59, 0.525]
        var priceCenters = centers.map { $0 + 0.026 }
        let tilted = columns(names: names, nameCenters: centers, prices: prices, priceCenters: priceCenters, height: 0.020)
        XCTAssertEqual(ReceiptLineOrdering.lines(from: tilted), pairedRows(names, prices))

        priceCenters[2] += 0.026
        let outlier = columns(
            names: names, nameCenters: centers, prices: prices, priceCenters: priceCenters, height: 0.020
        )
        XCTAssertEqual(ReceiptLineOrdering.lines(from: outlier), zip(prices, names).flatMap { [$0, $1] })
    }

    private func columns(
        names: [String], nameCenters: [CGFloat], prices: [String], priceCenters: [CGFloat], height: CGFloat
    ) -> [TextFragment] {
        let left = zip(names, nameCenters).map { text, y in
            TextFragment(text: text, box: CGRect(x: 0.08, y: y - height / 2, width: 0.30, height: height))
        }
        let right = zip(prices, priceCenters).map { text, y in
            TextFragment(text: text, box: CGRect(x: 0.70, y: y - height / 2, width: 0.12, height: height))
        }
        return Array(right.reversed()) + left
    }

    private func pairedRows(_ names: [String], _ prices: [String]) -> [String] {
        zip(names, prices).map { "\($0) \($1)" }
    }
}
