import XCTest
@testable import Vesta

final class ReceiptConfirmLinesTests: XCTestCase {
    private func line(_ net: String = "10", kind: ReceiptLine.LineKindPayload = .item,
                      gross: String? = nil, discount: String = "0", name: String = "Item",
                      unit: String? = nil) -> ReceiptLine {
        .init(discountAmount: discount, grossLineTotal: gross ?? net, lineKind: kind,
              netLineTotal: net, quantity: "1", rawName: name, rawUnit: unit)
    }

    private func plan(_ original: [ReceiptLine], draft: [ReceiptLine]? = nil,
                      total: String = "10", kind: BudgetReceiptSummaryWire.DocumentKindPayload = .receipt) throws -> ReceiptConfirmLinePlan {
        try ReceiptConfirmLines.planConfirmLines(documentKind: kind, originalLines: original,
                                                draftLines: draft ?? original, total: total)
    }

    func testExactSumAndEquivalentEditsKeepStoredLines() throws {
        let original = [line("3", unit: " "), line("7")]
        var draft = original
        draft[0].rawName = " Item\t"
        draft[0].rawUnit = nil
        draft[0].quantity = "01,000"
        draft[0].grossLineTotal = "3.0"
        draft[0].netLineTotal = "03.00"
        XCTAssertFalse(ReceiptConfirmLines.haveConfirmLinesChanged(original, draft))
        let result = try plan(original, draft: draft)
        XCTAssertNil(result.lines)
        XCTAssertNil(result.adjustment)
    }

    func testExactSumWithEditsSendsCleanLines() throws {
        let result = try plan([line()], draft: [line("010,000", name: " Z\u{0307}ółty\t\n ser ", unit: " szt. ")])
        let sent = try XCTUnwrap(result.lines?.first)
        XCTAssertEqual(sent.rawName, "Żółty ser")
        XCTAssertEqual(sent.rawName.unicodeScalars.first?.value, 0x017B)
        XCTAssertEqual(sent.rawUnit, "szt.")
        XCTAssertEqual(sent.netLineTotal, "10")
        XCTAssertNil(result.adjustment)
    }

    func testRemainderBalancesExactly() throws {
        let result = try plan([line("6.0101"), line("3.9898")])
        XCTAssertEqual(result.adjustment, .remainder(amount: "0.0001"))
        XCTAssertEqual(result.lines?.map(\.netLineTotal), ["6.0101", "3.9898", "0.0001"])
        let remainder = try XCTUnwrap(result.lines?.last)
        XCTAssertEqual(remainder.rawName, "Pozostałe / nierozpoznane pozycje")
        XCTAssertEqual(remainder.lineKind, .item)
        XCTAssertEqual(remainder.quantity, "1")
        XCTAssertEqual(remainder.grossLineTotal, "0.0001")
        XCTAssertEqual(remainder.discountAmount, "0")
        XCTAssertNil(remainder.unitPriceRaw)
        XCTAssertEqual(ReceiptConfirmLines.computeLinesDelta(result.lines?.map(\.netLineTotal) ?? [], total: "10"), 0)
    }

    func testExcessAndInvalidLinesAreReplacedBySummary() throws {
        for original in [[line("11")], [line("8", gross: "7")], [line("7", name: "\u{200D}Item")]] {
            let result = try plan(original)
            XCTAssertEqual(result.adjustment, .summary)
            XCTAssertEqual(result.lines?.count, 1)
            let summary = try XCTUnwrap(result.lines?.first)
            XCTAssertEqual(summary.rawName, "Tylko suma")
            XCTAssertEqual(summary.lineKind, .other)
            XCTAssertEqual(summary.quantity, "1")
            XCTAssertEqual(summary.netLineTotal, "10")
            XCTAssertEqual(summary.grossLineTotal, "10")
            XCTAssertEqual(summary.discountAmount, "0")
        }
    }

    func testLineLimitIncludesRemainder() throws {
        let zero = line("0")
        let atLimit = Array(repeating: zero, count: 300)
        XCTAssertEqual(try plan(atLimit).adjustment, .summary)
        XCTAssertEqual(try plan(atLimit + [line()]).adjustment, .summary)
        XCTAssertEqual(try plan(Array(atLimit.dropLast())).lines?.count, 300)
        XCTAssertNil(try plan(Array(atLimit.dropLast()) + [line()]).lines)
    }

    func testRedactedLinesAreNeverEchoed() throws {
        let variants = [line("7", name: " [usunięto] "), line("7", unit: "[usunie\u{0328}to]"),
                        line("7", name: PANRedactor.placeholder)]
        for redacted in variants {
            let result = try plan([redacted])
            XCTAssertEqual(result.adjustment, .summary)
            XCTAssertEqual(result.lines?.map(\.rawName), ["Tylko suma"])
            let exact = try plan([redacted], total: "7")
            XCTAssertNil(exact.adjustment)
            XCTAssertNil(exact.lines)
        }
    }

    func testEditingRedactedLinesIsBlocked() {
        let redacted = line(name: "[usunięto]")
        for (original, draft) in [([redacted], [line()]), ([line()], [redacted]), ([redacted], [])] {
            XCTAssertThrowsError(try plan(original, draft: draft)) {
                XCTAssertEqual($0 as? ReceiptConfirmLineError, .redactedLinesEditBlocked)
            }
        }
    }

    func testPaymentConfirmationRequiresExactLines() throws {
        XCTAssertNil(try plan([line()], kind: .paymentConfirmation).lines)
        for original in [[line("9")], [line("11")], [line("10", gross: "9")], []] {
            XCTAssertThrowsError(try plan(original, kind: .paymentConfirmation)) {
                XCTAssertEqual($0 as? ReceiptConfirmLineError, .totalMismatch)
            }
        }
        XCTAssertThrowsError(try plan([line(name: "")], kind: .paymentConfirmation)) {
            XCTAssertEqual($0 as? ReceiptConfirmLineError, .invalidForm)
        }
    }

    func testMoneyRejectsIdentifiersAfterNormalization() throws {
        XCTAssertNil(ReceiptConfirmLines.normalizeConfirmMoney("0123456789,0300")) // checksum-valid 11 digits
        XCTAssertNil(ReceiptConfirmLines.normalizeConfirmMoney("-123456789.03"))
        XCTAssertNil(ReceiptConfirmLines.normalizeConfirmMoney("123456789.123"))   // 12 digits
        XCTAssertEqual(ReceiptConfirmLines.normalizeConfirmMoney("123456789.04"), "123456789.04")
        XCTAssertEqual(ReceiptConfirmLines.normalizeConfirmMoney("\n01,2000\t"), "1.2")
        XCTAssertNil(ReceiptConfirmLines.normalizeConfirmMoney("01,20000"))
        XCTAssertNil(ReceiptConfirmLines.normalizeConfirmMoney(String(repeating: "0", count: 80) + "1"))

        var badMoney = line()
        badMoney.unitPriceRaw = "123456789.03"
        XCTAssertEqual(try plan([badMoney]).adjustment, .summary)
        XCTAssertEqual(try plan([line("0.02")], total: "123456789.05").adjustment, .summary)
    }

    func testLineTextChecksLengthControlsAndSplitIdentifiers() throws {
        let longName = String(repeating: "🧾", count: 128)
        let longUnit = String(repeating: "j", count: 16)
        XCTAssertNoThrow(try ReceiptConfirmLines.cleanConfirmLine(line(name: longName, unit: longUnit)))
        for invalid in [line(name: "\u{0301}"), line(name: longName + "x"), line(unit: longUnit + "x"),
                        line(name: "Item\u{007F}"), line(unit: "\u{000B}"),
                        line(name: "Item １２３４５６", unit: "١٢٣٤٥٦")] {
            XCTAssertThrowsError(try ReceiptConfirmLines.cleanConfirmLine(invalid)) {
                XCTAssertEqual($0 as? ReceiptConfirmLineError, .invalidForm)
            }
        }
    }

    func testMathAndLineKindSigns() throws {
        let accepted = [line("6", gross: "10", discount: "4"), line("0"),
                        line("2", kind: .deposit), line("-2", kind: .deposit),
                        line("-2", kind: .basketDiscount), line("-2", kind: .other),
                        line("0", kind: .other)]
        for allowed in accepted {
            XCTAssertNoThrow(try ReceiptConfirmLines.cleanConfirmLine(allowed))
        }

        let rejected = [line("-2"), line("2", gross: "1", discount: "-1"), line("-1", gross: "1", discount: "2"),
                        line("0", kind: .deposit), line("1", kind: .deposit, gross: "2", discount: "1"),
                        line("0", kind: .basketDiscount), line("2", kind: .basketDiscount),
                        line("-2", kind: .basketDiscount, gross: "-1", discount: "1"),
                        line("2", kind: .other, gross: "3", discount: "1"), line("2", gross: "3")]
        for invalid in rejected {
            XCTAssertThrowsError(try ReceiptConfirmLines.cleanConfirmLine(invalid)) {
                XCTAssertEqual($0 as? ReceiptConfirmLineError, .totalMismatch)
            }
        }
    }

    func testEmptyInvoiceKeepsStoredLinesAndHidesAdjustment() throws {
        let result = try plan([], kind: .invoice)
        XCTAssertNil(result.lines)
        XCTAssertNil(result.adjustment)
        XCTAssertEqual(try plan([]).adjustment, .remainder(amount: "10"))
    }

    func testAdjustmentOnlyShownForSuccessfulFallback() {
        func adjustment(_ lines: [ReceiptLine], total: String = "10",
                        kind: BudgetReceiptSummaryWire.DocumentKindPayload? = nil) -> ReceiptTotalAdjustment? {
            ReceiptConfirmLines.receiptTotalAdjustment(documentKind: kind, originalLines: lines,
                                                       draftLines: lines, total: total)
        }
        XCTAssertEqual(adjustment([line("9")]), .remainder(amount: "1"))
        XCTAssertEqual(adjustment([line("11")]), .summary)
        XCTAssertNil(adjustment([line()]))
        XCTAssertNil(adjustment([line()], total: "invalid"))
        XCTAssertNil(adjustment([line("9")], kind: .paymentConfirmation))
        XCTAssertNil(adjustment([], kind: .invoice))
    }
}
