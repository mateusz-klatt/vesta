import CoreGraphics
import XCTest
@testable import Vesta

final class ReceiptCurvedDiscountSafetyTests: XCTestCase {
    func testCurvedPairingRefusesTwoSignedAmountsForSameDiscount() {
        // Both signed amounts are within the raw band tolerance of OPUST BATON.
        let fragments = discountConflict(itemY: 0.6595, signedY: 0.6455) + [
            fragment("-0,50 A", x: 0.767, y: 0.6385, width: 0.06),
            fragment("DODATEK", x: 0.19, y: 0.636, width: 0.30),
        ]
        assertLegacyBands(fragments, conflict: [
            "BATON", "OPUST BATON 1szt * 7,89 7,89 A", "DODATEK", "-1,23 A", "-0,50 A",
        ])
    }

    func testCurvedPairingRefusesWhenSecondDiscountLabelFits() {
        // The same signed amount is within tolerance of both discount labels.
        let fragments = discountConflict(itemY: 0.6605, signedY: 0.6405) + [
            fragment("OPUST CHLEB", x: 0.32, y: 0.6385, width: 0.12, slope: 0.04),
        ]
        assertLegacyBands(fragments, conflict: [
            "BATON", "OPUST BATON 1szt * 7,89 7,89 A", "OPUST CHLEB", "-1,23 A",
        ])
    }

    func testCurvedPairingDoesNotCrossExistingPrice() {
        // Reattaching the calculation would move it above 9,50 B in the price column.
        let fragments = discountConflict(itemY: 0.6595, signedY: 0.6395) + [
            fragment("9,50 B", x: 0.75, y: 0.6737, width: 0.06),
            fragment("DODATEK", x: 0.19, y: 0.67, width: 0.30),
        ]
        assertLegacyBands(fragments, conflict: [
            "DODATEK", "BATON 9,50 B", "OPUST BATON 1szt * 7,89 7,89 A", "-1,23 A",
        ])
    }

    private func discountConflict(itemY: CGFloat, signedY: CGFloat) -> [TextFragment] {
        [
            fragment("BATON", x: 0.19, y: 0.6625, width: 0.30, slope: 0.04),
            fragment("1szt * 7,89 7,89 A", x: 0.71, y: itemY, width: 0.10),
            fragment("OPUST BATON", x: 0.18, y: 0.6455, width: 0.32, slope: 0.04),
            fragment("-1,23 A", x: 0.75, y: signedY, width: 0.06),
        ]
    }

    private func assertLegacyBands(
        _ fragments: [TextFragment], conflict: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        // Give the curved fit surrounding evidence on both sides of the conflict.
        let rows: [(name: String, amount: String, y: CGFloat, rise: CGFloat)] = [
            ("WODA", "2,00 B", 0.86, -0.007), ("SOK", "4,00 B", 0.80, -0.00665),
            ("CHLEB", "5,00 B", 0.50, -0.00665), ("MLEKO", "6,00 B", 0.44, -0.007),
        ]
        let surrounding = rows.flatMap { name, amount, y, rise in
            [fragment(name, x: 0.19, y: y, width: 0.30), fragment(amount, x: 0.75, y: y + rise, width: 0.06)]
        }
        XCTAssertEqual(
            ReceiptLineOrdering.lines(from: surrounding + fragments),
            ["WODA 2,00 B", "SOK 4,00 B"] + conflict + ["CHLEB 5,00 B", "MLEKO 6,00 B"],
            file: file, line: line
        )
    }

    private func fragment(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, slope: CGFloat? = nil) -> TextFragment {
        TextFragment(text: text, box: CGRect(x: x, y: y, width: width, height: 0.015), rowSlope: slope)
    }
}
