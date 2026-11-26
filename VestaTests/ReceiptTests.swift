import XCTest
import CoreGraphics
import Foundation
import HTTPTypes
import OpenAPIRuntime
import UIKit
@testable import Vesta

// MARK: - PAN redaction

final class PANRedactorTests: XCTestCase {
    private let visa = "4111111111111111"            // Luhn-valid test PAN

    func testLuhn() {
        XCTAssertTrue(PANRedactor.luhnValid(visa))
        XCTAssertTrue(PANRedactor.luhnValid("5555555555554444"))
        XCTAssertFalse(PANRedactor.luhnValid("4111111111111112"))
        XCTAssertFalse(PANRedactor.luhnValid(""))
    }

    func testRedactsLuhnValidRunAnywhere() {
        XCTAssertEqual(PANRedactor.redact("x \(visa) y"), "x [REDACTED] y")
    }

    func testRedactsGroupedPAN() {
        XCTAssertEqual(PANRedactor.redact("4111 1111 1111 1111"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("4111-1111-1111-1111"), "[REDACTED]")
    }

    func testKeepsLuhnInvalidLongNumberOutsideCardBlock() {
        // A receipt serial that fails Luhn and sits far from any card label.
        XCTAssertEqual(PANRedactor.redact("NR SYS 4111111111111112"), "NR SYS 4111111111111112")
    }

    func testKeepsShortNumbers() {
        let text = "NIP 123-456-78-90\nMLEKO 1 x 3,49 3,49 A\nSUMA PLN 45,99"
        XCTAssertEqual(PANRedactor.redact(text), text)
    }

    func testCardBlockCatchesAmountShapedPAN() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 422222222.2222"), "NR KARTY: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("KARTA\n4222,22222,2222"), "KARTA\n[REDACTED]")
        // Amounts and dates in the block survive.
        let block = "KARTA VISA\nKWOTA 45,99 PLN\nDATA 23.11.2026 18:04"
        XCTAssertEqual(PANRedactor.redact(block), block)
    }

    func testRedactsMaskedPANs() {
        XCTAssertEqual(PANRedactor.redact("****1234"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("5351********1234"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("XXXX XXXX XXXX 1234"), "[REDACTED]")
    }

    func testCardBlockRedactsTerminalNumbersButKeepsAmounts() {
        let text = """
        KARTA PLATNICZA 45,99 PLN
        NR KARTY: 53511234
        AID A0000000041010
        TERMINAL 12345678
        21:37 2026-11-23
        """
        let out = PANRedactor.redact(text).components(separatedBy: "\n")
        XCTAssertEqual(out[0], "KARTA PLATNICZA 45,99 PLN")          // amount survives
        XCTAssertEqual(out[1], "NR KARTY: [REDACTED]")
        XCTAssertEqual(out[2], "AID [REDACTED]")
        XCTAssertEqual(out[3], "TERMINAL [REDACTED]")
        XCTAssertEqual(out[4], "21:37 2026-11-23")                    // time/date survive
    }

    func testCardBlockWindowEnds() {
        let text = "CARD\na\nb\nc\nd\nZBN 12345678"
        // The block covers the label and its three following lines.
        XCTAssertTrue(PANRedactor.redact(text).hasSuffix("ZBN 12345678"))
    }

    func testLabelIsCaseInsensitive() {
        XCTAssertEqual(PANRedactor.redact("nr karty 12345678"), "nr karty [REDACTED]")
    }

    // Bypasses found in review.

    func testIrregularSpacingAndOCRLookalikes() {
        XCTAssertEqual(PANRedactor.redact("4111  1111 1111 1111"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("VISA: 4O00 0000 0000 0002"), "VISA: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("4l11 1111 1111 1111"), "[REDACTED]")
    }

    func testColonGluedNumberAndSplitMaskTail() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY:53511234"), "NR KARTY:[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("KARTA: **** 12 34"), "KARTA: [REDACTED]")
    }

    func testLowercaseAIDAndStandaloneARQC() {
        XCTAssertEqual(PANRedactor.redact("aid a0000000041010"), "aid [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("ARQC 9f3c2b1a0d4e5f60"), "ARQC [REDACTED]")
    }

    func testPANNextToDateIsRedactedDateKept() {
        XCTAssertEqual(PANRedactor.redact("2026-11-23 4111 1111 1111 1111"), "2026-11-23 [REDACTED]")
    }

    // False positives found in review.

    func testKeepsNIPInsideCardBlock() {
        XCTAssertEqual(PANRedactor.redact("KARTA\nNIP 7791011327"), "KARTA\nNIP 7791011327")
        XCTAssertEqual(PANRedactor.redact("KARTA\nNIP 779-101-13-27"), "KARTA\nNIP 779-101-13-27")
    }

    func testKeepsAmountAfterMaskChars() {
        XCTAssertEqual(PANRedactor.redact("SUMA PLN ****45,99"), "SUMA PLN ****45,99")
    }

    func testKeepsDayFirstDateInsideCardBlock() {
        XCTAssertEqual(PANRedactor.redact("KARTA\n23-11-2026 1234"), "KARTA\n23-11-2026 1234")
    }

    func testDateShapedPANFragmentsAreStillRedacted() {
        XCTAssertEqual(PANRedactor.redact("CARD: 4111-11-11 1111 1111"), "CARD: [REDACTED]")
    }

    func testLetterGluedPAN() {
        XCTAssertEqual(PANRedactor.redact("VISA4111111111111111"), "VISA[REDACTED]")
    }

    func testOverlappingWindowsLeaveNoTail() {
        XCTAssertEqual(PANRedactor.redact("1111 4111 1111 1111 1111"), "[REDACTED]")
    }

    func testPANGluedInsideLongerDigitRun() {
        XCTAssertFalse(PANRedactor.redact("9994111111111111111999").contains("4111111111111111"))
    }

    func testManyShortGroupsStayFast() {
        let line = String(repeating: "1 ", count: 16_000)
        let start = Date()
        _ = PANRedactor.redact(line)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testNIPChecksum() {
        XCTAssertTrue(PANRedactor.validNIP("7791011327"))
        XCTAssertFalse(PANRedactor.validNIP("1234567890"))
        XCTAssertFalse(PANRedactor.validNIP("779101132"))
    }

    // Exact-output regressions from the second PAN review.

    func testOCRSInsideCompactMastercard() {
        XCTAssertEqual(PANRedactor.redact("MASTERCARD: 55555S5555554444"), "MASTERCARD: [REDACTED]")
    }

    func testOCROAndZInGroupedVisa() {
        XCTAssertEqual(PANRedactor.redact("VISA: 4000 00O0 0000 000Z"), "VISA: [REDACTED]")
    }

    func testOCRSWithoutCardLabel() {
        XCTAssertEqual(PANRedactor.redact("5555 5S55 5555 4444"), "[REDACTED]")
    }

    func testOCRSBeforeFinalMastercardGroups() {
        XCTAssertEqual(PANRedactor.redact("MASTERCARD: 5555 555S 5555 4444"), "MASTERCARD: [REDACTED]")
    }

    func testOCRBAndGWithoutCardLabels() {
        XCTAssertEqual(PANRedactor.redact("37B2 B22463 10005"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("G011 1111 1111 1117"), "[REDACTED]")
    }

    func testAlreadyFixedWrappedAndAllLookAlikeGroups() {
        XCTAssertEqual(PANRedactor.redact("4111 1111\n1111 1111"), "[REDACTED]\n[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111\n1111 1111 1111"), "NR KARTY: [REDACTED]\n[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY:\n4111 11\n11 1111\n1111"), "NR KARTY:\n[REDACTED]\n[REDACTED]\n[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("4111 llll 1111 1111"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("VISA: 4111 llll 1111 1111"), "VISA: [REDACTED]")
    }

    func testMaskedPANWithTailOnNextOCRLine() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY:\n**** **** ****\n1234"), "NR KARTY:\n[REDACTED]\n[REDACTED]")
    }

    func testEnDashSeparator() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111–1111–1111–1111"), "NR KARTY: [REDACTED]")
    }

    func testSlashSeparator() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111/1111/1111/1111"), "NR KARTY: [REDACTED]")
    }

    func testThreeSpacesAsSeparator() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111   1111   1111   1111"), "NR KARTY: [REDACTED]")
    }

    func testTabSeparator() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111\t1111\t1111\t1111"), "NR KARTY: [REDACTED]")
    }

    func testNonbreakingSpaceSeparator() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111\u{00A0}1111\u{00A0}1111\u{00A0}1111"), "NR KARTY: [REDACTED]")
    }

    func testThinSpaceEmDashAndMinusSeparators() {
        XCTAssertEqual(PANRedactor.redact("4111\u{2009}1111—1111−1111"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("4111—11**\u{2009}****−1111"), "[REDACTED]")
    }

    func testInflectedPaymentLabelBeforeDottedPAN() {
        XCTAssertEqual(PANRedactor.redact("PŁATNOŚĆ KARTĄ\n4111.1111.1111.1111"), "PŁATNOŚĆ KARTĄ\n[REDACTED]")
    }

    func testInflectedPaymentLabelWithAmountShapedPAN() {
        XCTAssertEqual(PANRedactor.redact("PŁATNOŚĆ KARTĄ: 422222222.2222"), "PŁATNOŚĆ KARTĄ: [REDACTED]")
    }

    func testPolishInflectionsAndTerminalBrandsStartCardWindow() {
        for label in ["KARCIE", "KARTĘ", "PLATNOSC KARTA", "VPAY", "JCB", "DINERS", "UNIONPAY", "POLCARD", "ESERVICE"] {
            XCTAssertEqual(PANRedactor.redact("\(label)\nT: 12345678"), "\(label)\nT: [REDACTED]")
        }
    }

    func testTerminalIdentifierRefreshesCardWindow() {
        XCTAssertEqual(
            PANRedactor.redact("KARTA VISA\nZBLIŻENIOWO\nSPRZEDAŻ\nTID: 12345678\nNR: 422222222.2222"),
            "KARTA VISA\nZBLIŻENIOWO\nSPRZEDAŻ\nTID: [REDACTED]\nNR: [REDACTED]"
        )
    }

    func testDottedDayFirstDateInsidePAN() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111 11.11.1111 1111"), "NR KARTY: [REDACTED]")
    }

    func testGluedWordAfterPANPreservesWord() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111111111111111ONLINE"), "NR KARTY: [REDACTED]ONLINE")
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 411111111111111lONLINE"), "NR KARTY: [REDACTED]ONLINE")
    }

    func testGluedOCRGlyphAfterPAN() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111111111111111l"), "NR KARTY: [REDACTED]")
    }

    func testGluedPrefixInCompactPAN() {
        XCTAssertEqual(PANRedactor.redact("014111111111111111"), "[REDACTED]")
    }

    func testGluedPrefixInFirstGroupOfPAN() {
        XCTAssertEqual(PANRedactor.redact("014111 1111 1111 1111"), "[REDACTED]")
    }

    func testMaskedPANWithGroupedBIN() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111 11** **** 1111"), "NR KARTY: [REDACTED]")
    }

    func testMaskedPANWithDoubleSpacedGroups() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: XXXX  XXXX  XXXX  1234"), "NR KARTY: [REDACTED]")
    }

    func testMaskedPANWithThreeAsterisks() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 411111***1111"), "NR KARTY: [REDACTED]")
    }

    func testMaskedPANWithAsciiDots() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 411111......1111"), "NR KARTY: [REDACTED]")
    }

    func testMaskedPANWithMiddleDots() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: ···· ···· ···· 1234"), "NR KARTY: [REDACTED]")
    }

    func testMaskedPANWithOCRTail() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: **** 123O"), "NR KARTY: [REDACTED]")
    }

    func testFullWidthPAN() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY: ４１１１ １１１１ １１１１ １１１１"), "NR KARTY: [REDACTED]")
    }

    func testFullWidthDigitGluedToAsciiPAN() {
        XCTAssertEqual(PANRedactor.redact("4111111111111111１"), "[REDACTED]")
    }

    func testSupplementaryDecimalDigitPreservesOffsets() {
        XCTAssertEqual(
            PANRedactor.redact("🧾 \u{1D7DC}111 1111 1111 1111 🧾 NIP ０００１２３４５６２"),
            "🧾 [REDACTED] 🧾 NIP ０００１２３４５６２"
        )
    }

    func testKeepsFiscalsAndPolishUnitsNearDigits() {
        XCTAssertEqual(PANRedactor.redact("""
        PARAGON FISKALNY
        EAN 2900000000070
        NR SYS 4111111111111112
        Mąka 500G 2 SZT x 4,99 9,98 A
        Witamina B12 1 x 22,90 22,90 B
        SUMA PLN 32,88 ZŁ
        23.11.2026\t17:08:03
        """), """
        PARAGON FISKALNY
        EAN 2900000000070
        NR SYS 4111111111111112
        Mąka 500G 2 SZT x 4,99 9,98 A
        Witamina B12 1 x 22,90 22,90 B
        SUMA PLN 32,88 ZŁ
        23.11.2026\t17:08:03
        """)
    }

    func testKeepsFiscalFieldsAndLoyaltyAcrossTerminalBoundary() {
        XCTAssertEqual(PANRedactor.redact("""
        eService VISA
        NIP nabywcy: 000-123-45-62
        KWOTA PLN 1\u{202F}250,30
        DATA 23/11/2026 17:08
        Karta lojalnościowa: 2900000002079
        NR PARAGONU 00015824
        """), """
        eService VISA
        NIP nabywcy: 000-123-45-62
        KWOTA PLN 1\u{202F}250,30
        DATA 23/11/2026 17:08
        Karta lojalnościowa: 2900000002079
        NR PARAGONU 00015824
        """)
    }

    func testDottedReceiptLeadersAndPercentagesSurvive() {
        XCTAssertEqual(PANRedactor.redact("Mąka ........ 2 SZT"), "Mąka ........ 2 SZT")
        XCTAssertEqual(PANRedactor.redact("Cukier .... 500G"), "Cukier .... 500G")
        XCTAssertEqual(PANRedactor.redact("1. x 2 SZT"), "1. x 2 SZT")
        XCTAssertEqual(PANRedactor.redact("LICZBA POZYCJI ............ 12"), "LICZBA POZYCJI ............ 12")
        XCTAssertEqual(PANRedactor.redact("PUNKTY LOJALNOŚCIOWE ........ 120"), "PUNKTY LOJALNOŚCIOWE ........ 120")
        XCTAssertEqual(PANRedactor.redact("Pozycje 1 ... 25"), "Pozycje 1 ... 25")
        XCTAssertEqual(PANRedactor.redact("**** 20% ****"), "**** 20% ****")
        XCTAssertEqual(PANRedactor.redact("KARTA: ****12,34"), "KARTA: ****12,34")
    }

    func testMoneyColumnsInTerminalBlockSurvive() {
        XCTAssertEqual(
            PANRedactor.redact("PŁATNOŚĆ KARTĄ   145,99   145,99"),
            "PŁATNOŚĆ KARTĄ   145,99   145,99"
        )
        XCTAssertEqual(
            PANRedactor.redact("KARTA VISA\nKWOTA: 100,00   4,3215   432,15 PLN"),
            "KARTA VISA\nKWOTA: 100,00   4,3215   432,15 PLN"
        )
    }

    func testFiscalColumnBoundariesSeparateDatesWeightsAndPostalCodes() {
        XCTAssertEqual(PANRedactor.redact("2026-11-23  45.94"), "2026-11-23  45.94")
        XCTAssertEqual(PANRedactor.redact("23.11.2026  45.94"), "23.11.2026  45.94")
        XCTAssertEqual(PANRedactor.redact("23.11.2026  004214"), "23.11.2026  004214")
        XCTAssertEqual(PANRedactor.redact("Jabłka PLU 4015  1.250  4.99  6.24"), "Jabłka PLU 4015  1.250  4.99  6.24")
        XCTAssertEqual(PANRedactor.redact("00-950  22 123 45 66"), "00-950  22 123 45 66")
    }

    func testMultiColumnItemsAndVATTableSurvive() {
        assertExactRedaction("""
        SKLEP TESTOWY
        PARAGON FISKALNY
        Jabłka luz PLU 4015   1.250 kg  4.99  6.24 C
        Gruszki PLU 4024   0,850 kg  7,99  6,79 C
        Kawa mielona   2 SZT   19.90   39.80 A
        PTU     NETTO     PODATEK     BRUTTO
        A 23%   32.36     7.44        39.80
        C  5%   12.41     0.62        13.03
        SUMA PLN                      52.83
        23.11.2026   17:34:02   004214
        """, equals: """
        SKLEP TESTOWY
        PARAGON FISKALNY
        Jabłka luz PLU 4015   1.250 kg  4.99  6.24 C
        Gruszki PLU 4024   0,850 kg  7,99  6,79 C
        Kawa mielona   2 SZT   19.90   39.80 A
        PTU     NETTO     PODATEK     BRUTTO
        A 23%   32.36     7.44        39.80
        C  5%   12.41     0.62        13.03
        SUMA PLN                      52.83
        23.11.2026   17:34:02   004214
        """)
    }

    func testDCCAmountsAndRateSurviveCardRedaction() {
        assertExactRedaction("""
        eService — TERMINAL TESTOWY
        KARTA VISA: ************1234
        DCC  EUR 100,00   KURS 4,3215   PLN 432,15
        KWOTA: 100,00   4,3215   432,15 PLN
        MARŻA: 3,00%
        DATA: 23.11.2026 18:04
        """, equals: """
        eService — TERMINAL TESTOWY
        KARTA VISA: [REDACTED]
        DCC  EUR 100,00   KURS 4,3215   PLN 432,15
        KWOTA: 100,00   4,3215   432,15 PLN
        MARŻA: 3,00%
        DATA: 23.11.2026 18:04
        """)
        assertExactRedaction(
            "KARTA VISA\nKURS DCC: 4,4396\n4111 1111 1111 1111",
            equals: "KARTA VISA\nKURS DCC: 4,4396\n[REDACTED]"
        )
    }

    func testReceiptPostalCodeAndPhoneSurvive() {
        assertExactRedaction(
            "SKLEP TESTOWY\n00-950\t22 123 45 66\nTEL. +48 000 000 000",
            equals: "SKLEP TESTOWY\n00-950\t22 123 45 66\nTEL. +48 000 000 000"
        )
    }

    func testWrappedMaskKeepsCardLabelAndRedactsBothBands() {
        XCTAssertEqual(PANRedactor.redact("NR KARTY\n4111 11** **\n** 1111"), "NR KARTY\n[REDACTED]\n[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("KARTA: 4111 11**\n**** 1111"), "KARTA: [REDACTED]\n[REDACTED]")
    }

    func testWrappedPANWithTrailingOCRColumns() {
        XCTAssertEqual(PANRedactor.redact("4111 1111\n1111 1111 PLN"), "[REDACTED]\n[REDACTED] PLN")
        XCTAssertEqual(PANRedactor.redact("4111 1111\n1111 1111 VISA"), "[REDACTED]\n[REDACTED] VISA")
    }

    func testWrappedPANSuffixAfterText() {
        XCTAssertEqual(
            PANRedactor.redact("KARTA VISA\nNR: 4111 11\n11 1111\n1111"),
            "KARTA VISA\nNR: [REDACTED]\n[REDACTED]\n[REDACTED]"
        )
        XCTAssertEqual(PANRedactor.redact("SPRZEDAŻ 4111 1111\n1111 1111"), "SPRZEDAŻ [REDACTED]\n[REDACTED]")
    }

    func testLowercaseOCRLookAlikes() {
        XCTAssertEqual(PANRedactor.redact("MASTERCARD: 55555s5555554444"), "MASTERCARD: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("5555 5s55 5555 4444"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("VISA: 4000 00O0 0000 000z"), "VISA: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("37b2 b22463 10005"), "[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("g011 1111 1111 1117"), "[REDACTED]")
    }

    func testTerminalIdentifierAndFourthLineReference() {
        XCTAssertEqual(
            PANRedactor.redact("KARTA VISA\nZBLIŻENIOWO\nSPRZEDAŻ\nNR TERMINALA: 12345678\nNR: 4222,22222,2222"),
            "KARTA VISA\nZBLIŻENIOWO\nSPRZEDAŻ\nNR TERMINALA: [REDACTED]\nNR: [REDACTED]"
        )
        XCTAssertEqual(
            PANRedactor.redact("KARTA VISA\nSPRZEDAŻ ZBLIŻENIOWA\nKWOTA: 45,99 PLN\nDATA: 23.11.2026 18:04\nNR: 53511234"),
            "KARTA VISA\nSPRZEDAŻ ZBLIŻENIOWA\nKWOTA: 45,99 PLN\nDATA: 23.11.2026 18:04\nNR: [REDACTED]"
        )
    }

    func testDottedMaskedTailsAndOCRPrefixes() {
        XCTAssertEqual(PANRedactor.redact("KARTA: ****12.34"), "KARTA: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY\n****12.34"), "NR KARTY\n[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY ****12,34"), "NR KARTY [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 41111l***1111"), "NR KARTY: [REDACTED]")
        XCTAssertEqual(PANRedactor.redact("NR KARTY: 4111 ll** **** 1111"), "NR KARTY: [REDACTED]")
    }

    func testGluedIssuerWithOCRDigitAndFleetCardPrefix() {
        XCTAssertEqual(PANRedactor.redact("MASTERCARDS555555555554444"), "MASTERCARD[REDACTED]")
        XCTAssertEqual(PANRedactor.redact("017000000000000005"), "[REDACTED]")
    }

    func testCombiningMarksOnDigitsAndAdjacentLetters() {
        assertExactRedaction("NR KARTY: 4111 111\u{0307}1 1111 1111", equals: "NR KARTY: [REDACTED]")
        assertExactRedaction("NR KARTY: 4111111111111111Z\u{0307}ABKA", equals: "NR KARTY: [REDACTED]Z\u{0307}ABKA")
    }

    private func assertExactRedaction(
        _ input: String, equals expected: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = PANRedactor.redact(input)
        if !actual.utf8.elementsEqual(expected.utf8) {
            XCTFail("Expected \(String(reflecting: expected)); got \(String(reflecting: actual))", file: file, line: line)
        }
    }
}

// MARK: - Line ordering

final class ReceiptLineOrderingTests: XCTestCase {
    private func frag(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.02,
                      slope: CGFloat? = nil) -> TextFragment {
        TextFragment(text: text, box: CGRect(x: x, y: y, width: w, height: h), rowSlope: slope)
    }

    func testTopToBottomLeftToRight() {
        // Shuffled on purpose: Vision gives no reading order.
        let fragments = [
            frag("3,49 A", x: 0.7, y: 0.80),
            frag("SKLEP", x: 0.1, y: 0.90),
            frag("MLEKO", x: 0.1, y: 0.80),
            frag("SUMA PLN 3,49", x: 0.1, y: 0.70),
        ]
        XCTAssertEqual(ReceiptLineOrdering.lines(from: fragments), ["SKLEP", "MLEKO 3,49 A", "SUMA PLN 3,49"])
    }

    func testSlightlySkewedFragmentsStayOnOneLine() {
        let fragments = [frag("CHLEB", x: 0.1, y: 0.500), frag("4,99", x: 0.7, y: 0.507)]
        XCTAssertEqual(ReceiptLineOrdering.lines(from: fragments), ["CHLEB 4,99"])
    }

    func testTiltedItemAmountsStayWithTheirRowsAboveAFlatFooter() {
        let fragments = [
            frag("30,00 B", x: 0.67, y: 0.666),
            frag("PŁYN", x: 0.1, y: 0.671, w: 0.24, slope: -0.06),
            frag("40,00", x: 0.67, y: 0.51),
            frag("PALIWO", x: 0.1, y: 0.70, w: 0.24, slope: -0.06),
            frag("10,00 A", x: 0.67, y: 0.637),
            frag("SUMA PLN", x: 0.1, y: 0.51, slope: 0),
        ]
        XCTAssertEqual(ReceiptLineOrdering.lines(from: fragments), ["PALIWO 30,00 B", "PŁYN 10,00 A", "SUMA PLN 40,00"])
    }

    func testSingleTiltedHeadingDoesNotShiftLevelItemRows() {
        let fragments = [
            frag("SKLEP", x: 0.2, y: 0.75, w: 0.42, slope: -0.10),
            frag("MLEKO", x: 0.1, y: 0.70),
            frag("4,00 A", x: 0.7, y: 0.70),
            frag("CHLEB", x: 0.1, y: 0.67),
            frag("5,00 A", x: 0.7, y: 0.67),
        ]
        XCTAssertEqual(ReceiptLineOrdering.lines(from: fragments), ["SKLEP", "MLEKO 4,00 A", "CHLEB 5,00 A"])
    }

    func testDropsBlankFragments() {
        XCTAssertEqual(ReceiptLineOrdering.lines(from: [frag("  ", x: 0, y: 0.5)]), [])
        XCTAssertEqual(ReceiptLineOrdering.lines(from: []), [])
    }
}

// MARK: - OCR retry

final class ReceiptOCRAssessmentTests: XCTestCase {
    private let clean = [
        "PALIWO 10L * 2,00 20,00 B",
        "ZAPAS 250ml 1szt × 8,99 8,99 A",
        "OPUST ZAPAS 250ml -0,01 A",
        "SUMA PLN 28,98",
        "KAUCJA 2 * 0,50 1,00",
        "DO ZAPŁATY 29,98",
    ]

    func testBalancedItemsDiscountAndDepositDoNotTriggerRetry() {
        XCTAssertFalse(ReceiptOCRAssessment(lines: clean).needsRetry)
    }

    func testRetryCanRecoverMisreadNumbersWhenPrintedTotalsAgree() {
        var illegible = clean
        illegible[0] = "10L * 9,02 04,43 B"
        illegible[4] = "KAUCJA 2 * 0.50 11,00"
        let primary = ReceiptOCRAssessment(lines: illegible)
        let alternate = ReceiptOCRAssessment(lines: clean)
        XCTAssertTrue(primary.needsRetry)
        XCTAssertTrue(alternate.improves(on: primary))
        XCTAssertFalse(primary.improves(on: alternate))
    }

    func testBetterItemsCannotOverrideADifferentPrintedTotalOrDropADiscount() {
        var illegible = clean
        illegible[0] = "10L * 9,02 04,43 B"
        let primary = ReceiptOCRAssessment(lines: illegible)

        var changedTotal = clean
        changedTotal[5] = "DO ZAPŁATY 20,98"
        XCTAssertFalse(ReceiptOCRAssessment(lines: changedTotal).improves(on: primary))

        var lostDiscount = clean
        lostDiscount.remove(at: 2)
        XCTAssertFalse(ReceiptOCRAssessment(lines: lostDiscount).improves(on: primary))
    }

    func testRetrySeparatesAnItemCalculationJoinedToADiscountLabel() {
        let retained = ["SOK 1szt * 4,00 4,00 A", "OPUST SOK 0,35 A"]
        let total = "SUMA PLN 10,75"
        let recovered = ["BATON 1szt * 7,50 7,50 A", "OPUST BATON -0,40 A", total]
        let alternate = ReceiptOCRAssessment(lines: retained + recovered)
        XCTAssertFalse(alternate.needsRetry)

        for count in ["1szt", "Iszt"] {
            let joined = "OPUST BATON \(count) * 7,50 7,50 A"
            let primary = ReceiptOCRAssessment(lines: retained + [joined, "-0,40 A", total])
            XCTAssertTrue(primary.needsRetry)
            XCTAssertTrue(alternate.improves(on: primary))

            let missingDiscount = ReceiptOCRAssessment(lines: [retained[0]] + recovered)
            XCTAssertFalse(missingDiscount.improves(on: primary))
        }
    }

    func testJoinedDiscountLabelTriggersRetryWithNoOtherItemCalculation() {
        let joined = "RABAT BATON Iszt = 7,50 7,50 A"
        XCTAssertTrue(ReceiptOCRAssessment(lines: [joined, "SUMA PLN 7,10"]).needsRetry)
        XCTAssertFalse(ReceiptOCRAssessment(lines: [joined]).needsRetry)
    }

    func testRetryCannotTradeAnAmbiguousItemForAnUnrelatedProductName() {
        let primary = ReceiptOCRAssessment(lines: [
            "1szt * 4,00 4,00 A", "OPUST BATON 1szt * 7,50 7,50 A", "SUMA PLN 11,10",
        ])
        let incomplete = ReceiptOCRAssessment(lines: ["SOK 1szt * 4,00 4,00 A", "SUMA PLN 11,10"])
        XCTAssertTrue(primary.needsRetry)
        XCTAssertFalse(incomplete.improves(on: primary))
    }

    func testRetryCanSeparateAJoinedCalculationAndSignedAmount() {
        let primary = ReceiptOCRAssessment(lines: ["OPUST BATON 1szt * 7,50 7,50 A -0,40 A", "SUMA PLN 7,10"])
        let complete = ReceiptOCRAssessment(lines: ["BATON 1szt * 7,50 7,50 A", "OPUST BATON -0,40 A", "SUMA PLN 7,10"])
        XCTAssertTrue(primary.needsRetry)
        XCTAssertTrue(complete.improves(on: primary))
    }

    func testRetryPreservesTheExplicitDiscountFromAJoinedLine() {
        let existingItem = "SOK 1szt * 4,00 4,00 A"
        let recoveredItem = "BATON 1szt * 7,50 7,50 A"
        let total = "SUMA PLN 11,10"
        let primary = ReceiptOCRAssessment(lines: [existingItem, "OPUST \(recoveredItem) -0,40 A", total])
        let complete = ReceiptOCRAssessment(lines: [existingItem, recoveredItem, "OPUST BATON -0,40 A", total])
        let reducedPrice = ReceiptOCRAssessment(lines: [existingItem, "BATON 1szt * 7,10 7,10 A", total])
        let splitDiscount = ReceiptOCRAssessment(lines: [
            existingItem, recoveredItem, "OPUST BATON -0,20 A", "OPUST BATON -0,20 A", total,
        ])
        XCTAssertTrue(complete.improves(on: primary))
        XCTAssertFalse(reducedPrice.improves(on: primary))
        XCTAssertFalse(splitDiscount.improves(on: primary))
    }

    func testRetryPreservesRepeatedAmountsThatMatchTheirCalculation() {
        let existingItem = "SOK 1szt * 4,00 4,00 A"
        let first = "CHLEB 1szt * 4,00 4,00 A"
        let second = "BATON 1szt * 7,50 7,50 A"
        let total = "SUMA PLN 15,50"
        let primary = ReceiptOCRAssessment(lines: [existingItem, "OPUST \(first)", "OPUST \(second)", total])
        let complete = ReceiptOCRAssessment(lines: [existingItem, first, second, total])
        let replacedRepeatedAmount = ReceiptOCRAssessment(lines: [
            existingItem, second, "CHLEB 1szt * 3,00 3,00 A", "MLEKO 1szt * 1,00 1,00 A", total,
        ])
        XCTAssertTrue(complete.improves(on: primary))
        XCTAssertFalse(replacedRepeatedAmount.improves(on: primary))
    }

    func testRetryCanCorrectAnAmountWithoutMatchingArithmetic() {
        let primary = ReceiptOCRAssessment(lines: ["OPUST BATON 2szt * 4,00 7,50 A -0,40 A", "SUMA PLN 7,60"])
        let complete = ReceiptOCRAssessment(lines: ["BATON 2szt * 4,00 8,00 A", "OPUST BATON -0,40 A", "SUMA PLN 7,60"])
        XCTAssertTrue(complete.improves(on: primary))
    }

    func testRetryCannotImproveByDroppingAnItemOrIntroducingADifferentPayableTotal() {
        let primary = ReceiptOCRAssessment(lines: [
            "PALIWO 2L * 5,00 4,00 B",
            "MLEKO 1 * 2,00 2,00 A",
            "SUMA PLN 12,00",
        ])
        let dropped = ReceiptOCRAssessment(lines: ["MLEKO 1 * 2,00 2,00 A", "SUMA PLN 12,00"])
        let changed = ReceiptOCRAssessment(lines: [
            "PALIWO 2L * 5,00 10,00 B",
            "MLEKO 1 * 2,00 2,00 A",
            "SUMA PLN 12,00",
            "DO ZAPŁATY 10,00",
        ])
        XCTAssertTrue(primary.needsRetry)
        XCTAssertFalse(dropped.improves(on: primary))
        XCTAssertFalse(changed.improves(on: primary))
    }

    @MainActor
    func testVisionKeepsPrintedAmountWhenRetryCannotReconcileIt() async throws {
        let rows = ["SKLEP TESTOWY", "PALIWO 2L * 5,00 4,00 B", "DO ZAPLATY 4,00"]
        let size = CGSize(width: 1_000, height: 390)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let style: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 46, weight: .semibold),
                .foregroundColor: UIColor.black,
            ]
            for (index, row) in rows.enumerated() {
                (row as NSString).draw(at: CGPoint(x: 36, y: 38 + 100 * index), withAttributes: style)
            }
        }

        let fragments = try await VisionReceiptRecognizer().recognize(XCTUnwrap(image.cgImage))
        let lines = ReceiptLineOrdering.lines(from: fragments)
        XCTAssertTrue(ReceiptOCRAssessment(lines: lines).needsRetry)
        XCTAssertTrue(lines.contains { $0.hasPrefix("DO ZAPLATY") && $0.contains("4,00") })
        XCTAssertFalse(lines.contains { $0.contains("10,00") })
    }
}

// MARK: - Limits + errors

final class ReceiptTextTests: XCTestCase {
    func testPrepareRedactsAndTrims() throws {
        XCTAssertEqual(try ReceiptText.prepare("  SKLEP  \n4111111111111111\n\n"), "SKLEP\n[REDACTED]")
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try ReceiptText.prepare(" \n ")) { XCTAssertEqual($0 as? ReceiptError, .rejected("empty_text")) }
    }

    func testRejectsTooManyLines() {
        let text = Array(repeating: "x", count: ReceiptText.maxLines + 1).joined(separator: "\n")
        XCTAssertThrowsError(try ReceiptText.prepare(text)) { XCTAssertEqual($0 as? ReceiptError, .tooLarge) }
    }

    func testRejectsTooManyBytes() {
        let text = String(repeating: "ż", count: ReceiptText.maxBytes / 2 + 1)   // 2 bytes each
        XCTAssertThrowsError(try ReceiptText.prepare(text)) { XCTAssertEqual($0 as? ReceiptError, .tooLarge) }
    }
}

final class ReceiptErrorMappingTests: XCTestCase {
    func testMapping() {
        XCTAssertEqual(ReceiptError.from(status: 404, code: "budget_receipts_disabled"), .disabled)
        XCTAssertEqual(ReceiptError.from(status: 404, code: nil), .notFound)
        XCTAssertEqual(ReceiptError.from(status: 403, code: nil), .forbidden)
        XCTAssertEqual(ReceiptError.from(status: 401, code: nil), .api(.unauthorized))
        XCTAssertEqual(ReceiptError.from(status: 413, code: "budget_receipt_quota_exceeded"), .draftQuota)
        XCTAssertEqual(ReceiptError.from(status: 413, code: nil), .tooLarge)
        XCTAssertEqual(ReceiptError.from(status: 409, code: "budget_receipt_conflict"), .versionConflict)
        XCTAssertEqual(ReceiptError.from(status: 409, code: "budget_receipt_tx_already_linked"), .alreadyLinked)
        XCTAssertEqual(ReceiptError.from(status: 409, code: "budget_receipt_stale_source"), .staleCandidate)
        XCTAssertEqual(ReceiptError.from(status: 409, code: "budget_requires_sqlite_users"), .rejected("budget_requires_sqlite_users"))
        XCTAssertEqual(ReceiptError.from(status: 400, code: "budget_receipt_total_mismatch"), .totalMismatch)
        XCTAssertEqual(ReceiptError.from(status: 400, code: "budget_invalid"), .rejected("budget_invalid"))
        XCTAssertEqual(ReceiptError.from(status: 400, code: nil), .rejected("invalid_request"))
        XCTAssertEqual(ReceiptError.from(status: 503, code: nil), .unavailable)
        XCTAssertEqual(ReceiptError.from(status: 500, code: "x"), .api(.http(500)))
    }

    func testWrapKeepsReceiptErrorAndMapsTransport() {
        XCTAssertEqual(ReceiptError.wrap(ReceiptError.disabled), .disabled)
        XCTAssertEqual(ReceiptError.wrap(URLError(.timedOut)), .api(.timedOut))
    }
}

// MARK: - Explicit nulls on confirm

final class ExplicitNullsMiddlewareTests: XCTestCase {
    func testFillsMissingKeysTopLevelAndPerLine() throws {
        let body = Data(#"{"receipt_id":"r","lines":[{"raw_name":"MLEKO"}]}"#.utf8)
        let keys = try XCTUnwrap(ExplicitNullsMiddleware.required["confirmBudgetReceipt"])
        let out = try ExplicitNullsMiddleware.fill(body, top: keys.top, lines: keys.lines)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(keys.top))
        XCTAssertTrue(object["link"] is NSNull)
        XCTAssertEqual(object["receipt_id"] as? String, "r")
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(line.keys), Set(keys.lines))
        XCTAssertTrue(line["ptu_code"] is NSNull)
        XCTAssertEqual(line["raw_name"] as? String, "MLEKO")
    }

    func testOtherOperationsPassThrough() async throws {
        let middleware = ExplicitNullsMiddleware()
        let request = HTTPRequest(method: .post, scheme: "https", authority: "h", path: "/x")
        let (response, body) = try await middleware.intercept(
            request, body: HTTPBody(#"{"a":1}"#), baseURL: URL(string: "https://h")!, operationID: "login"
        ) { _, body, _ in (HTTPResponse(status: .ok), body) }
        XCTAssertEqual(response.status, .ok)
        let echoed = try await String(collecting: try XCTUnwrap(body), upTo: 1024)
        XCTAssertEqual(echoed, #"{"a":1}"#)
    }
}

// MARK: - APIClient receipts calls

let sampleReceiptID = "0f8fad5b-d9cb-469f-a165-70867728950e"

let sampleParseJSON = #"""
{"receipt_id":"0f8fad5b-d9cb-469f-a165-70867728950e","version":1,
 "draft":{"receipt_id":"0f8fad5b-d9cb-469f-a165-70867728950e","shop_id":null,"chain_key":null,
  "raw_shop_name":"BIEDRONKA","raw_nip":"7791011327","receipt_kind":"purchase","receipt_date":"2026-11-22",
  "receipt_time":"18:04","total_amount":"7.98","currency":"PLN","payment_method":"card","status":"draft",
  "source_kind":"live_text","linked":false,"linked_account_id":null,"linked_entry_ref":null,"version":1,
  "created_at":1795400000.0,"updated_at":1795400000.0,"image_available":false,"image_expires_at":null,
  "raw_text_expires_at":1795572800.0,"math_delta":null,
  "lines":[
   {"line_no":1,"line_kind":"item","raw_name":"MLEKO","raw_name_key":"mleko","ptu_code":"C","quantity":"1",
    "raw_unit":null,"unit_price_raw":"3.49","gross_line_total":"3.49","discount_amount":"0","net_line_total":"3.49"},
   {"line_no":2,"line_kind":"item","raw_name":"CHLEB","raw_name_key":"chleb","ptu_code":"C","quantity":"1",
    "raw_unit":null,"unit_price_raw":"4.49","gross_line_total":"4.49","discount_amount":"0","net_line_total":"4.49"}]},
 "candidates":[{"account_id":"acc1","entry_reference":"tx1","amount":"7.98","currency":"PLN",
  "credit_debit_indicator":"DBIT","transaction_date":"2026-11-22","booking_date":"2026-11-23","value_date":null,
  "merchant_token_hit":true,"match_strength":"nip","date_distance":0,"candidate_token":"tok-1234567890123456789012345678901234567"}]}
"""#

private func body(_ s: String) -> Data { Data(s.utf8) }

/// Records the final request and body bytes (after every middleware) and
/// answers with a canned status + JSON.
final class CapturingTransport: ClientTransport, @unchecked Sendable {
    private let status: Int
    private let response: String
    private let lock = NSLock()
    private var captured: (request: HTTPRequest, body: Data)?
    var last: (request: HTTPRequest, body: Data)? { lock.withLock { captured } }

    init(status: Int, body: String) { (self.status, self.response) = (status, body) }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let data = if let body { try await Data(collecting: body, upTo: 1 << 20) } else { Data() }
        lock.withLock { captured = (request, data) }
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(self.response))
    }
}

@MainActor
final class ReceiptsClientTests: XCTestCase {
    private func pairedClient(transport: any ClientTransport) -> APIClient {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        return APIClient(transport: transport, receiptPairing: ReceiptPairing(store: store))
    }

    func testParseDecodesDraftAndCandidates() async throws {
        let api = pairedClient(transport: StubTransport { request in
            XCTAssertEqual(request.path, "/api/budget/receipts/parse-text")
            return (200, body(sampleParseJSON))
        })
        let result = try await api.parseReceiptText("BIEDRONKA", source: .paste)
        XCTAssertEqual(result.receiptId, sampleReceiptID)
        XCTAssertEqual(result.draft.lines.count, 2)
        XCTAssertEqual(result.draft.summary.totalAmount, "7.98")
        XCTAssertEqual(result.candidates.first?.entryReference, "tx1")
    }

    func testParseDisabledMapped() async {
        let api = pairedClient(transport: StubTransport { _ in (404, body(#"{"error":{"code":"budget_receipts_disabled"}}"#)) })
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .disabled)
    }

    func testParseForbiddenWithEmptyBody() async {
        let api = pairedClient(transport: StubTransport { _ in (403, nil) })
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .forbidden)
    }

    func testParseQuotaMapped() async {
        let api = pairedClient(transport: StubTransport { _ in (413, body(#"{"ok":false,"error":"budget_receipt_quota_exceeded"}"#)) })
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .draftQuota)
    }

    func testConfirmWireBodyHasEveryKeyIncludingNulls() async throws {
        let transport = CapturingTransport(status: 409, body: #"{"ok":false,"error":"budget_receipt_stale_source"}"#)
        let api = pairedClient(transport: transport)
        let parsed = try JSONDecoder().decode(ReceiptParseResult.self, from: body(sampleParseJSON))
        var form = ReceiptForm(draft: parsed.draft, candidates: parsed.candidates)
        form.time = ""
        form.payment = .cash                       // → link: null
        let request = try XCTUnwrap(form.request(receiptID: parsed.receiptId, version: parsed.version, candidates: parsed.candidates))
        await assertReceiptError(try await api.confirmReceipt(request), .staleCandidate)

        let sent = try XCTUnwrap(transport.last)
        XCTAssertEqual(sent.request.path, "/api/budget/receipts/confirm")
        XCTAssertEqual(sent.request.headerFields[.contentLength], String(sent.body.count))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        let keys = try XCTUnwrap(ExplicitNullsMiddleware.required["confirmBudgetReceipt"])
        XCTAssertEqual(Set(object.keys), Set(keys.top))
        XCTAssertTrue(object["link"] is NSNull)
        XCTAssertTrue(object["receipt_time"] is NSNull)
        let line = try XCTUnwrap((object["lines"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(line.keys), Set(keys.lines))
        XCTAssertTrue(line["raw_unit"] is NSNull)
    }

    func testBudgetDisabledMapped() {
        XCTAssertEqual(ReceiptError.from(status: 404, code: "budget_disabled"), .disabled)
    }

    func testDeleteOK() async throws {
        let api = pairedClient(transport: StubTransport { _ in (200, body(#"{"ok":true,"deleted":true}"#)) })
        try await api.deleteReceipt(id: sampleReceiptID, expectedVersion: 1)
    }

    func testOnlyReceiptOperationsSendTheDeviceToken() async throws {
        let store = MemoryDeviceTokenStore(.init(
            server: AppConfig.serverURL, provenance: .legacyPasswordLogin, actor: "u", credential: fakeDeviceToken
        ))
        let transport = CapturingTransport(status: 400, body: #"{"error":{"code":"budget_auth_ambiguous"}}"#)
        let api = APIClient(transport: transport, receiptPairing: ReceiptPairing(store: store),
                            sessionStore: try testCredentialSessionStore(token: "fake-session-token"))

        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .ambiguousAuth)
        assertBearer(transport, path: "/api/budget/receipts/parse-text", bearer: "fake-device-token")

        let parsed = try JSONDecoder().decode(ReceiptParseResult.self, from: body(sampleParseJSON))
        let form = ReceiptForm(draft: parsed.draft, candidates: parsed.candidates)
        let confirm = try XCTUnwrap(form.request(receiptID: parsed.receiptId, version: 1, candidates: parsed.candidates))
        await assertReceiptError(try await api.confirmReceipt(confirm), .ambiguousAuth)
        assertBearer(transport, path: "/api/budget/receipts/confirm", bearer: "fake-device-token")

        await assertReceiptError(try await api.deleteReceipt(id: sampleReceiptID, expectedVersion: 1), .ambiguousAuth)
        assertBearer(transport, path: "/api/budget/receipts/delete", bearer: "fake-device-token")

        _ = try? await api.whoami()
        assertBearer(transport, path: "/api/whoami", bearer: "fake-session-token")
    }

    private func assertBearer(_ transport: CapturingTransport, path: String, bearer: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(transport.last?.request.path, path, file: file, line: line)
        XCTAssertEqual(transport.last?.request.headerFields[.authorization], "Bearer \(bearer)", file: file, line: line)
        XCTAssertNil(transport.last?.request.headerFields[.cookie], file: file, line: line)
    }

    func testAllDeviceAuthorizedOperationIDsUseTheDeviceToken() async throws {
        let operations = [
            ("parseBudgetReceiptText", "parse-text"), ("confirmBudgetReceipt", "confirm"),
            ("deleteBudgetReceipt", "delete"), ("searchBudgetReceipts", "search"),
            ("getBudgetReceiptImage", "image"), ("revokeBudgetReceiptDevice", "device-token/revoke"),
        ]
        let server = AppConfig.serverURL
        let store = MemoryDeviceTokenStore(.init(server: server, credential: fakeDeviceToken))
        let session = BoundSession(origin: server, actor: nil, token: "fake-session-token")
        let middleware = BearerAuthMiddleware(session: session, receiptPairing: ReceiptPairing(store: store))

        for (operation, suffix) in operations {
            let path = "/api/budget/receipts/\(suffix)"
            let transport = CapturingTransport(status: 200, body: "{}")
            let request = HTTPRequest(method: .post, scheme: server.scheme, authority: server.host, path: path)
            _ = try await middleware.intercept(request, body: nil, baseURL: server, operationID: operation) { request, body, url in
                try await transport.send(request, body: body, baseURL: url, operationID: operation)
            }
            assertBearer(transport, path: path, bearer: fakeDeviceToken.token)
        }
    }

    func testRedeemAndOtherBudgetRoutesNeverGetTheLoginBearer() async throws {
        let server = AppConfig.serverURL
        let store = MemoryDeviceTokenStore(.init(server: server, credential: fakeDeviceToken))
        let session = BoundSession(origin: server, actor: nil, token: "fake-session-token")
        let middleware = BearerAuthMiddleware(session: session, receiptPairing: ReceiptPairing(store: store))
        let routes = [
            ("redeemBudgetReceiptDevice", "/api/budget/receipts/device-token/redeem"),
            ("futureBudgetOperation", "/api/budget/future"),
        ]
        for (operation, path) in routes {
            let transport = CapturingTransport(status: 200, body: "{}")
            var request = HTTPRequest(method: .post, scheme: server.scheme, authority: server.host, path: path)
            request.headerFields[.authorization] = "Bearer fake-session-token"
            request.headerFields[.cookie] = "fake-cookie"
            _ = try await middleware.intercept(request, body: nil, baseURL: server, operationID: operation) { request, body, url in
                try await transport.send(request, body: body, baseURL: url, operationID: operation)
            }
            let sent = try XCTUnwrap(transport.last?.request)
            XCTAssertNil(sent.headerFields[.authorization])
            XCTAssertNil(sent.headerFields[.cookie])
        }
    }

    func testUnpairedReceiptsNeverFallBackToTheSessionToken() async throws {
        let transport = CapturingTransport(status: 403, body: "")
        let api = APIClient(transport: transport, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
                            sessionStore: try testCredentialSessionStore(token: "fake-session-token"))
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .pairAgain)
        XCTAssertNil(transport.last)
    }

    func testScopedReceiptRejectsAReplacedCredentialBeforeSending() async throws {
        let origin = URL(string: "https://hestia.example")!
        let replacement = ReceiptDeviceToken(token: "fake-new-device", tokenID: "replacement", expiresAt: .number(1))
        let store = MemoryDeviceTokenStore(.init(server: origin, credential: replacement))
        let pairing = ReceiptPairing(store: store, serverURL: { origin })
        let transport = CapturingTransport(status: 200, body: sampleParseJSON)
        let api = APIClient(transport: transport, receiptPairing: pairing)
        let oldScope = ReceiptSessionScope(origin: origin, actor: nil, ownerKey: nil, credential: fakeDeviceToken)

        do {
            _ = try await api.parseReceiptText("Receipt text", source: .paste, scope: oldScope)
            XCTFail("The old operation must not send the replacement credential")
        } catch is CancellationError {
            XCTAssertNil(transport.last)
        }
    }

    func testExpiredTokenIsRemovedAndRequiresPairingAgain() async {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(store: store)
        let api = APIClient(transport: CapturingTransport(status: 401, body: #"{"error":{"code":"device_token_expired"}}"#),
                            receiptPairing: pairing)
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .pairAgain)
        XCTAssertNil(store.load())
        XCTAssertEqual(pairing.status, .pairAgain)
    }

    func testRevokedTokenIsRemovedEvenOnDraftCleanup() async {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(store: store)
        let api = APIClient(transport: CapturingTransport(status: 401, body: #"{"error":{"code":"device_token_revoked"}}"#),
                            receiptPairing: pairing)
        await assertReceiptError(try await api.deleteReceipt(id: sampleReceiptID, expectedVersion: 1), .pairAgain)
        XCTAssertNil(store.load())
        XCTAssertEqual(pairing.status, .pairAgain)
    }

    func testParseRateLimitDoesNotClearCredential() async {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(store: store)
        let api = APIClient(transport: StubTransport { _ in (429, nil) }, receiptPairing: pairing)
        await assertReceiptError(try await api.parseReceiptText("x", source: .paste), .rateLimited)
        XCTAssertEqual(pairing.status, .paired)
        XCTAssertNotNil(store.load())
    }
}

@MainActor
func assertReceiptError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: ReceiptError,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected to throw \(expected)", file: file, line: line)
    } catch let error as ReceiptError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("threw \(error), expected \(expected)", file: file, line: line)
    }
}

// MARK: - Form

final class ReceiptFormTests: XCTestCase {
    private func parsed() throws -> ReceiptParseResult {
        try JSONDecoder().decode(ReceiptParseResult.self, from: body(sampleParseJSON))
    }

    func testFromDraftPreselectsSingleCardCandidate() throws {
        let p = try parsed()
        let form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        XCTAssertEqual(form.shopName, "BIEDRONKA")
        XCTAssertEqual(form.payment, .card)
        XCTAssertEqual(form.candidate, ReceiptForm.CandidateID(p.candidates[0]))
        XCTAssertEqual(form.day?.iso, "2026-11-22")
        XCTAssertNil(form.mismatch)
        XCTAssertTrue(form.isValid)
    }

    func testRequestCarriesLinkAndCanonicalFields() throws {
        let p = try parsed()
        let request = try XCTUnwrap(ReceiptForm(draft: p.draft, candidates: p.candidates)
            .request(receiptID: p.receiptId, version: p.version, candidates: p.candidates))
        XCTAssertEqual(request.receiptDate, "2026-11-22")
        XCTAssertEqual(request.totalAmount, "7.98")
        XCTAssertEqual(request.link?.entryReference, "tx1")
        XCTAssertEqual(request.link?.candidateToken, p.candidates[0].candidateToken)
        XCTAssertEqual(request.lines?.map(\.netLineTotal), ["3.49", "4.49"])
    }

    func testCashNeverLinks() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.payment = .cash
        XCTAssertNil(form.request(receiptID: p.receiptId, version: 1, candidates: p.candidates)?.link)
    }

    func testSameEntryOnTwoAccountsPicksTheChosenAccount() throws {
        let p = try parsed()
        let a = p.candidates[0]
        var b = a
        b.accountId = "acc2"
        b.candidateToken = "tok-b"
        var form = ReceiptForm(draft: p.draft, candidates: [a, b])
        form.candidate = .init(b)
        let link = try XCTUnwrap(form.request(receiptID: p.receiptId, version: 1, candidates: [a, b])?.link)
        XCTAssertEqual(link.accountId, "acc2")
        XCTAssertEqual(link.candidateToken, "tok-b")
    }

    func testEditingShopOrNIPDropsTheStaleLink() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.shopName = "BIEDRONKA 123"
        XCTAssertTrue(form.matchFieldsEdited)
        XCTAssertNil(form.request(receiptID: p.receiptId, version: 1, candidates: p.candidates)?.link)
    }

    func testWhitespaceOnlyShopEditKeepsTheLink() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.shopName = "  BIEDRONKA \t"
        XCTAssertFalse(form.matchFieldsEdited)
        XCTAssertNotNil(form.request(receiptID: p.receiptId, version: 1, candidates: p.candidates)?.link)
    }

    func testWhitespaceEditOfAMaxLengthShopSendsTheSignedName() throws {
        var p = try parsed()
        let signed = String(repeating: "A", count: 64) + " " + String(repeating: "B", count: 63)
        p.draft.summary.rawShopName = signed
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.shopName = String(repeating: "A", count: 64) + "  " + String(repeating: "B", count: 63)
        XCTAssertFalse(form.matchFieldsEdited)
        let request = try XCTUnwrap(form.request(receiptID: p.receiptId, version: 1, candidates: p.candidates))
        XCTAssertEqual(request.rawShopName, signed)
        XCTAssertNotNil(request.link)
        // Past the cap the truncated value differs, so the link is dropped.
        form.shopName = signed + "C"
        XCTAssertFalse(form.matchFieldsEdited)    // the cap cuts the extra character
        form.shopName = "X" + signed
        XCTAssertTrue(form.matchFieldsEdited)
    }

    func testShopFieldIsRedactedOnTheWire() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.shopName = "SKLEP 4111 1111 1111 1111"
        XCTAssertEqual(form.request(receiptID: p.receiptId, version: 1, candidates: [])?.rawShopName, "SKLEP [REDACTED]")
    }

    func testMissingDateMustBePicked() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.day = nil
        XCTAssertFalse(form.isValid)
        XCTAssertNil(form.request(receiptID: p.receiptId, version: 1, candidates: []))
    }

    func testCalendarDayRoundTripsThroughPickerDate() throws {
        let day = try XCTUnwrap(ReceiptDay(iso: "2026-11-22"))
        XCTAssertEqual(ReceiptDay(date: day.date), day)
        XCTAssertNil(ReceiptDay(iso: "2026-02-30"))
    }

    func testInvalidLineSignsBlockSave() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        var bad = form.lines[0]
        bad.grossLineTotal = "3"
        bad.discountAmount = "4"
        bad.netLineTotal = "-1"
        form.lines = [bad, form.lines[1]]
        form.total = "3.49"
        XCTAssertEqual(form.invalidLines, [1])
        XCTAssertFalse(form.isValid)
    }

    func testMismatchAndValidation() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.total = "8.00"
        XCTAssertEqual(form.mismatch, Decimal(string: "0.02"))
        XCTAssertFalse(form.isValid)
        form.total = " 7,98 "                      // comma + stray spaces from the keyboard
        XCTAssertNil(form.mismatch)
        XCTAssertEqual(form.request(receiptID: p.receiptId, version: 1, candidates: [])?.totalAmount, "7.98")
        form.total = "007,98000"                   // canonicalised to what hestia accepts
        XCTAssertEqual(form.request(receiptID: p.receiptId, version: 1, candidates: [])?.totalAmount, "7.98")
        form.total = "7.98765"                     // > 4 decimals: hestia rejects
        XCTAssertFalse(form.isValid)
        form.total = "7.98"
        form.nip = "123"
        XCTAssertFalse(form.isValid)
        form.nip = "1234567890"                    // right length, bad checksum
        XCTAssertFalse(form.isValid)
        form.nip = ""
        form.time = "25:00"
        XCTAssertFalse(form.isValid)
    }

    func testMoneyMatchesHestiaFormat() {
        XCTAssertNil(ReceiptForm.money("1e3"))
        XCTAssertNil(ReceiptForm.money("abc"))
        XCTAssertNil(ReceiptForm.money("1234567890"))        // > 9 integer digits
        XCTAssertEqual(ReceiptForm.money(" 12,50 "), "12.5")
        XCTAssertEqual(ReceiptForm.money("-3"), "-3")
        XCTAssertEqual(ReceiptForm.money("000000007,9800"), "7.98")
        XCTAssertEqual(ReceiptForm.money("-0.00"), "0")
        XCTAssertNil(ReceiptForm.money("7.98765"))
    }
}

// MARK: - Flow

actor MockReceiptsAPI: ReceiptsAPI {
    enum Call: Equatable { case parse(String, ReceiptSourceKind = .paste), confirm(String?), delete(String, Int) }
    private(set) var calls: [Call] = []
    private(set) var scopes: [ReceiptSessionScope?] = []
    private var parseError: ReceiptError?
    private var deleteError: ReceiptError?
    private var parseGate: CheckedContinuation<Void, Never>?
    private var holdParse = false
    private var deleteGate: CheckedContinuation<Void, Never>?
    private var holdDelete = false

    func failParse(_ error: ReceiptError) { parseError = error }
    func failDelete(_ error: ReceiptError?) { deleteError = error }
    func holdNextParse() { holdParse = true }
    func releaseParse() { parseGate?.resume(); parseGate = nil }
    func holdNextDelete() { holdDelete = true }
    func releaseDelete() { deleteGate?.resume(); deleteGate = nil }

    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult {
        calls.append(.parse(text, source))
        scopes.append(scope)
        if holdParse {
            holdParse = false
            await withCheckedContinuation { parseGate = $0 }
        }
        if let parseError { throw parseError }
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8))
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail {
        calls.append(.confirm(request.link?.entryReference))
        scopes.append(scope)
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8)).draft
    }

    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws {
        calls.append(.delete(id, expectedVersion))
        scopes.append(scope)
        if holdDelete {
            holdDelete = false
            await withCheckedContinuation { deleteGate = $0 }
        }
        if let deleteError { throw deleteError }
    }
}

extension ReceiptSessionScope {
    static func testScope(origin: URL = URL(string: "https://hestia.example")!) -> Self {
        .init(origin: origin, actor: nil, ownerKey: nil, credential: nil)
    }
}

extension ReceiptFlow {
    convenience init(api: any ReceiptsAPI,
                     recognizer: any ReceiptTextRecognizing = VisionReceiptRecognizer(),
                     allowsMatching: @escaping @MainActor () -> Bool = { true },
                     janitor: ReceiptDraftJanitor = ReceiptDraftJanitor(),
                     scope: ReceiptSessionScope = .testScope()) {
        self.init(api: api, recognizer: recognizer, allowsMatching: allowsMatching, janitor: janitor,
                  scope: scope, isScopeCurrent: { $0 == scope }, isCleanupScopeCurrent: { $0 == scope })
    }
}

struct StubRecognizer: ReceiptTextRecognizing {
    let fragments: [TextFragment]
    func recognize(_: CGImage) async throws -> [TextFragment] { fragments }
}

@MainActor
final class ReceiptTests: XCTestCase {
    @MainActor
    private final class MatchGrant {
        var isGranted = true
    }

    func testCameraAcceptsOnlyOnePhotoPerPresentation() {
        let picker = UIImagePickerController()
        let photo = UIImage()
        var images: [UIImage?] = []
        let coordinator = ReceiptCamera.Coordinator { images.append($0) }

        coordinator.imagePickerController(picker, didFinishPickingMediaWithInfo: [.originalImage: photo])
        coordinator.imagePickerController(picker, didFinishPickingMediaWithInfo: [.originalImage: UIImage()])
        coordinator.imagePickerControllerDidCancel(picker)

        XCTAssertEqual(images.count, 1)
        XCTAssertTrue(images.first.flatMap { $0 } === photo)
    }

    func testRotatedPhotoIsUprightForReceiptOCR() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10), format: format).image {
            UIColor.black.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        }
        let pixels = try XCTUnwrap(photo.cgImage)
        let rotated = UIImage(cgImage: pixels, scale: 1, orientation: .right)
        let upright = try XCTUnwrap(rotated.uprightReceiptImage)

        XCTAssertEqual(upright.width, 10)
        XCTAssertEqual(upright.height, 20)
    }

    func test409AlreadySubmittedAndLegacyLinkNullConfirm() async throws {
        let origin = URL(string: "https://hestia.example")!
        let store = MemoryDeviceTokenStore(.init(server: origin, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(store: store, serverURL: { origin })
        let transport = AlreadySubmittedTransport()
        let api = APIClient(transport: transport, receiptPairing: pairing)
        let scope = ReceiptSessionScope(origin: origin, actor: nil, ownerKey: nil, credential: fakeDeviceToken)
        let flow = ReceiptFlow(api: api, scope: scope)
        flow.useText("BIEDRONKA")
        await flow.send()
        flow.form.payment = .cash

        await flow.confirm()
        await flow.confirm()
        await flow.abandon()

        XCTAssertEqual(flow.step, .done)
        XCTAssertNil(flow.parsed)
        XCTAssertNil(flow.error)
        let operations = await transport.operations
        XCTAssertEqual(operations, [Operations.ParseBudgetReceiptText.id, Operations.ConfirmBudgetReceipt.id])
        let sent = await transport.confirmBody
        let body = try XCTUnwrap(sent)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertTrue(object["link"] is NSNull)
    }

    func testMatchLossClearsOpenReviewCandidatesAndFormSelection() async throws {
        let api = MockReceiptsAPI()
        let matchGrant = MatchGrant()
        let flow = ReceiptFlow(api: api, allowsMatching: { matchGrant.isGranted }, janitor: ReceiptDraftJanitor())
        flow.useText("Receipt text")
        await flow.send()

        XCTAssertEqual(flow.step, .review)
        XCTAssertFalse(flow.candidates.isEmpty)
        XCTAssertNotNil(flow.form.candidate)

        matchGrant.isGranted = false
        flow.updateMatchAccess()

        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.candidates.isEmpty)
        XCTAssertNil(flow.form.candidate)
        matchGrant.isGranted = true
        flow.updateMatchAccess()
        XCTAssertTrue(flow.candidates.isEmpty)
        XCTAssertNil(flow.form.candidate)

        await flow.backToEdit()
        await api.holdNextParse()
        let reading = Task { await flow.send() }
        defer { Task { await api.releaseParse() } }
        try await waitUntil("the held receipt reparse") { await api.calls.count == 3 }
        matchGrant.isGranted = false
        flow.updateMatchAccess()
        await api.releaseParse()
        await reading.value

        XCTAssertEqual(flow.step, .review)
        XCTAssertTrue(flow.candidates.isEmpty)
        XCTAssertNil(flow.form.candidate)
        await flow.confirm()
        XCTAssertEqual(flow.step, .done)
        let calls = await api.calls
        XCTAssertEqual(calls, [
            .parse("Receipt text"), .delete(sampleReceiptID, 1), .parse("Receipt text"), .confirm(nil),
        ])
    }
}

private actor AlreadySubmittedTransport: ClientTransport {
    private(set) var operations: [String] = []
    private(set) var confirmBody: Data?

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        operations.append(operationID)
        var response: HTTPResponse
        let json: String
        if operationID == Operations.ParseBudgetReceiptText.id {
            response = HTTPResponse(status: .ok)
            json = sampleParseJSON
        } else {
            if operationID == Operations.ConfirmBudgetReceipt.id, let body {
                confirmBody = try await Data(collecting: body, upTo: 1 << 20)
            }
            response = HTTPResponse(status: .conflict)
            json = #"{"error":{"code":"already_submitted"}}"#
        }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

@MainActor
final class ReceiptFlowTests: XCTestCase {
    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testRecognizeOrdersAndRedactsBeforeShowing() async {
        let recognizer = StubRecognizer(fragments: [
            TextFragment(text: "4111111111111111", box: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.02)),
            TextFragment(text: "SKLEP", box: CGRect(x: 0.1, y: 0.9, width: 0.3, height: 0.02)),
        ])
        let flow = ReceiptFlow(api: MockReceiptsAPI(), recognizer: recognizer)
        await flow.recognize([image()])
        XCTAssertEqual(flow.step, .edit)
        XCTAssertEqual(flow.text, "SKLEP\n[REDACTED]")
    }

    func testParseWireSourceKindTracksEditedOCRAndPaste() async throws {
        let transport = CapturingTransport(status: 200, body: sampleParseJSON)
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let api = APIClient(transport: transport, receiptPairing: ReceiptPairing(store: store))
        let recognizer = StubRecognizer(fragments: [
            TextFragment(text: "OCR text", box: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.02)),
        ])
        let scope = ReceiptSessionScope(origin: AppConfig.serverURL, actor: nil, ownerKey: nil,
                                        credential: fakeDeviceToken)
        let flow = ReceiptFlow(api: api, recognizer: recognizer, scope: scope)
        await flow.recognize([image()])
        flow.text = "Edited OCR text"
        await flow.send()
        let ocr = try XCTUnwrap(transport.last)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: ocr.body),
                       ["text": "Edited OCR text", "source_kind": "local_ocr"])
        XCTAssertEqual(flow.step, .review)

        let pasteFlow = ReceiptFlow(api: api, scope: scope)
        pasteFlow.useText("Pasted text")
        await pasteFlow.send()
        let paste = try XCTUnwrap(transport.last)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: paste.body),
                       ["text": "Pasted text", "source_kind": "paste"])
        XCTAssertEqual(pasteFlow.step, .review)
    }

    func testSendThenConfirmHappyPath() async {
        let api = MockReceiptsAPI()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("BIEDRONKA\nSUMA PLN 7,98")
        await flow.send()
        XCTAssertEqual(flow.step, .review)
        XCTAssertEqual(flow.form.candidate?.entry, "tx1")
        await flow.confirm()
        XCTAssertEqual(flow.step, .done)
        let calls = await api.calls
        XCTAssertEqual(calls, [.parse("BIEDRONKA\nSUMA PLN 7,98"), .confirm("tx1")])
    }

    func testRereadDiscardsPreviousDraft() async {
        let api = MockReceiptsAPI()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("A")
        await flow.send()
        await flow.backToEdit()
        XCTAssertEqual(flow.step, .edit)
        let calls = await api.calls
        XCTAssertEqual(calls.last, .delete(sampleReceiptID, 1))
    }

    func testAbandonWhileParsingDeletesTheLateDraft() async throws {
        let api = MockReceiptsAPI()
        await api.holdNextParse()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("A")
        let sending = Task { await flow.send() }
        while await api.calls.isEmpty { await Task.yield() }
        await flow.abandon()                       // sheet closed mid-request
        await api.releaseParse()
        await sending.value
        let calls = await api.calls
        XCTAssertEqual(calls, [.parse("A"), .delete(sampleReceiptID, 1)])
        XCTAssertNotEqual(flow.step, .review)
    }

    func testFailedDeleteIsRetriedByALaterFlow() async {
        let api = MockReceiptsAPI()
        let janitor = ReceiptDraftJanitor()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor)
        flow.useText("A")
        await flow.send()
        await api.failDelete(.api(.offline))
        await flow.backToEdit()
        await flow.abandon()                       // sheet closes while still offline
        let stillQueued = await janitor.pendingCount
        XCTAssertEqual(stillQueued, 1)
        await api.failDelete(nil)
        let next = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor)
        await next.abandon()                       // any later flow drains the queue
        let drained = await janitor.pendingCount
        XCTAssertEqual(drained, 0)
        let deletes = await api.calls.filter { if case .delete = $0 { true } else { false } }
        XCTAssertEqual(deletes.count, 3)
    }

    func testQueuedDeletesOnlyGoToTheirOwnServer() async {
        let api = MockReceiptsAPI()
        let janitor = ReceiptDraftJanitor()
        let scope = ReceiptSessionScope.testScope()
        let otherScope = ReceiptSessionScope.testScope(origin: URL(string: "https://hestia.example:8443")!)
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor, scope: scope)
        flow.useText("A")
        await flow.send()
        await api.failDelete(.api(.offline))
        await flow.abandon()                       // A's draft stays queued
        await api.failDelete(nil)
        let onB = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor, scope: otherScope)
        await onB.abandon()
        var deletes = await api.calls.filter { if case .delete = $0 { true } else { false } }
        XCTAssertEqual(deletes.count, 1)           // nothing sent to B
        let queued = await janitor.pendingCount
        XCTAssertEqual(queued, 1)
        let backOnA = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor, scope: scope)
        await backOnA.abandon()
        deletes = await api.calls.filter { if case .delete = $0 { true } else { false } }
        XCTAssertEqual(deletes.count, 2)
        let drained = await janitor.pendingCount
        XCTAssertEqual(drained, 0)
    }

    func testCancelDuringCleanupSendsNoText() async {
        let api = MockReceiptsAPI()
        let janitor = ReceiptDraftJanitor()
        await janitor.enqueue(.init(id: "old", version: 1, scope: .testScope()))
        await api.holdNextDelete()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor)
        flow.useText("A")
        let sending = Task { await flow.send() }
        while await api.calls.isEmpty { await Task.yield() }
        await flow.abandon()                       // closed while the old draft is deleted
        await api.releaseDelete()
        await sending.value
        let calls = await api.calls
        XCTAssertEqual(calls, [.delete("old", 1)])
    }

    func testOverlappingAndLateSendsIssueOneRequest() async {
        let api = MockReceiptsAPI()
        await api.holdNextParse()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("A")
        let first = Task { await flow.send() }
        while await api.calls.isEmpty { await Task.yield() }
        await flow.send()                          // double tap: ignored while busy
        await api.releaseParse()
        await first.value
        await flow.send()                          // an already queued tap after advancing to review
        let parses = await api.calls.filter { if case .parse = $0 { true } else { false } }
        XCTAssertEqual(parses.count, 1)
        XCTAssertEqual(flow.step, .review)
    }

    func testSendErrorStaysOnEdit() async {
        let api = MockReceiptsAPI()
        await api.failParse(.forbidden)
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("A")
        await flow.send()
        XCTAssertEqual(flow.step, .edit)
        XCTAssertEqual(flow.error, .forbidden)
    }

    func testOnlyAdminSeesReceipts() {
        XCTAssertTrue(Control.canAddReceipts(role: "admin"))
        XCTAssertFalse(Control.canAddReceipts(role: "operator"))
        XCTAssertFalse(Control.canAddReceipts(role: "viewer"))
        XCTAssertFalse(Control.canAddReceipts(role: nil))
    }
}
