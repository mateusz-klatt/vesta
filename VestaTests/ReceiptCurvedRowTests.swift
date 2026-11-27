import CoreGraphics
import Foundation
import XCTest
@testable import Vesta

final class ReceiptCurvedRowTests: XCTestCase {
    func testCurvedFuelReceiptPairsNamesWithAmounts() {
        assertFuelRows(tilt: 1)
    }

    func testCurvedFuelReceiptPairsNamesWithAmountsOnOppositeTilt() {
        assertFuelRows(tilt: -1)
    }

    func testStraightFuelReceiptKeepsTheSameRows() {
        assertFuelRows(tilt: 0)
    }

    private func assertFuelRows(tilt: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let receipt: [(name: String, amount: String?)] = [
            ("PARAGON FISKALNY", nil),
            ("FUEL95 ACT. Pompa # 3", "10,00L * 6,00 60,00 B"),
            ("WASHER FLUID 3.5L EKO, szt", "1szt * 30,00 30,00 A"),
            ("DRINK XY 250ml, sz", "1szt * 9,00 9,00 A"),
            ("OPUST DRINK XY 250ml, sz", "-1,50 A"),
            ("DRINK XY 250ml, sz", "1szt * 9,00 9,00 A"),
            ("OPUST DRINK XY 250ml, sz", "-1,50 A"),
            ("Suma Opustów", "-3,00"),
            ("SUMA PLN", "105,00"),
            ("OPAKOWANIA ZWROTNE WYDANIA", nil),
            ("DRS KAUCJA PUSZKA", "2 * 0,50 1,00"),
            ("OPAKOWANIA ZWROTNE SUMA", "1,00"),
            ("DO ZAPŁATY", "106,00"),
        ]
        let fragments = receipt.enumerated().flatMap { index, row -> [TextFragment] in
            let left = CGRect(x: 0.08, y: 0.89 - CGFloat(index) * 0.035,
                              width: 0.014 * CGFloat(row.name.count), height: 0.014)
            let name = TextFragment(text: row.name, box: left)
            guard let price = row.amount else { return [name] }

            let progress = CGFloat(index) / CGFloat(receipt.count - 1)
            let radians = (2 + 2 * progress) * CGFloat.pi / 180
            let priceWidth = CGFloat(price.count) * 0.014
            let priceX = 0.91 - priceWidth
            let run = priceX + priceWidth / 2 - left.midX
            let rise = tilt * (tan(radians) * run + 0.0015 * sin(progress * CGFloat.pi))
            let right = CGRect(x: priceX, y: left.minY + rise, width: priceWidth, height: left.height)
            return [TextFragment(text: price, box: right), name]
        }
        let expected = receipt.map { [$0.name, $0.amount].compactMap { $0 }.joined(separator: " ") }
        XCTAssertEqual(ReceiptLineOrdering.lines(from: Array(fragments.reversed())), expected, file: file, line: line)
    }
}
