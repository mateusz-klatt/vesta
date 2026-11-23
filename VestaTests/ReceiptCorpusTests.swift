import XCTest
@testable import Vesta

/// Synthetic Vision OCR text in reading order. Shop details, tax identifiers,
/// and terminal references are fictional. Full PANs are public test numbers.
final class ReceiptCorpusTests: XCTestCase {
    func testBiedronkaMaskedContactlessPayment() {
        assertReceipt("""
        BIEDRONKA — SKLEP TESTOWY 001
        NIP 000-123-45-62
        PARAGON FISKALNY
        Mleko 2%             1 x 3,49  3,49 C
        Chleb żytni          1 x 4,99  4,99 C
        SPRZEDAŻ OPODATKOWANA C       8,48
        PTU C 5%                      0,40
        SUMA PLN                      8,48
        Rozliczenie płatności
        Karta płatnicza               8,48
        NR KARTY: ************1234
        23.11.2026 18:04  NR PARAGONU 004218
        """, becomes: """
        BIEDRONKA — SKLEP TESTOWY 001
        NIP 000-123-45-62
        PARAGON FISKALNY
        Mleko 2%             1 x 3,49  3,49 C
        Chleb żytni          1 x 4,99  4,99 C
        SPRZEDAŻ OPODATKOWANA C       8,48
        PTU C 5%                      0,40
        SUMA PLN                      8,48
        Rozliczenie płatności
        Karta płatnicza               8,48
        NR KARTY: [REDACTED]
        23.11.2026 18:04  NR PARAGONU 004218
        """)
    }

    func testBiedronkaLoyaltyAndBuyerNIPBeforePayment() {
        assertReceipt("""
        BIEDRONKA — SKLEP TESTOWY 002
        NIP 0007654325
        PARAGON FISKALNY
        Jabłka luz  PLU 4015     1,200 x 4,99  5,99 C
        Karta Moja Biedronka: 2900000046123
        Rabat Moja Biedronka                 -1,00
        NIP nabywcy: 000-456-78-96
        SUMA PLN                              4,99
        KARTA PŁATNICZA                        4,99
        MASTERCARD 5555 5555 5555 4444
        """, becomes: """
        BIEDRONKA — SKLEP TESTOWY 002
        NIP 0007654325
        PARAGON FISKALNY
        Jabłka luz  PLU 4015     1,200 x 4,99  5,99 C
        Karta Moja Biedronka: 2900000046123
        Rabat Moja Biedronka                 -1,00
        NIP nabywcy: 000-456-78-96
        SUMA PLN                              4,99
        KARTA PŁATNICZA                        4,99
        MASTERCARD [REDACTED]
        """)
    }

    func testLidlEANPLUAndGroupedVisa() {
        assertReceipt("""
        LIDL — SKLEP TESTOWY 013
        PARAGON FISKALNY
        Woda gazowana  EAN 2900000102019
                                 2 x 2,49  4,98 A
        Banany         PLU 4011  1,520 x 5,49  8,34 C
        SPRZEDAŻ OPODATKOWANA A  4,98
        SPRZEDAŻ OPODATKOWANA C  8,34
        PTU A 23% 0,93
        PTU C  5% 0,40
        SUMA PLN 13,32
        VISA: 4111  1111 1111 1111
        """, becomes: """
        LIDL — SKLEP TESTOWY 013
        PARAGON FISKALNY
        Woda gazowana  EAN 2900000102019
                                 2 x 2,49  4,98 A
        Banany         PLU 4011  1,520 x 5,49  8,34 C
        SPRZEDAŻ OPODATKOWANA A  4,98
        SPRZEDAŻ OPODATKOWANA C  8,34
        PTU A 23% 0,93
        PTU C  5% 0,40
        SUMA PLN 13,32
        VISA: [REDACTED]
        """)
    }

    func testLidlCashAndLoyaltyWithoutPaymentCard() {
        assertReceipt("""
        LIDL — SKLEP TESTOWY 014
        PARAGON FISKALNY
        Bułka grahamka      4 x 0,89  3,56 C
        Karta lojalnościowa: 2900000002079
        SUMA PLN             3,56
        Gotówka             10,00
        Reszta               6,44
        NR PARAGONU  00015824
        2026-11-23 08:02
        """, becomes: """
        LIDL — SKLEP TESTOWY 014
        PARAGON FISKALNY
        Bułka grahamka      4 x 0,89  3,56 C
        Karta lojalnościowa: 2900000002079
        SUMA PLN             3,56
        Gotówka             10,00
        Reszta               6,44
        NR PARAGONU  00015824
        2026-11-23 08:02
        """)
    }

    func testZabkaBareCardSuffix() {
        assertReceipt("""
        ŻABKA — PUNKT TESTOWY 021
        NIP 0002468109
        PARAGON FISKALNY
        Kawa z mlekiem  1 x 8,99  8,99 B
        PTU B 8%  0,67
        SUMA PLN  8,99
        Karta płatnicza  8,99
        NR KARTY: 1234
        23/11/2026 07:42:09
        """, becomes: """
        ŻABKA — PUNKT TESTOWY 021
        NIP 0002468109
        PARAGON FISKALNY
        Kawa z mlekiem  1 x 8,99  8,99 B
        PTU B 8%  0,67
        SUMA PLN  8,99
        Karta płatnicza  8,99
        NR KARTY: [REDACTED]
        23/11/2026 07:42:09
        """)
    }

    func testZabkaBLIKWithoutCardData() {
        assertReceipt("""
        ŻABKA — PUNKT TESTOWY 022
        PARAGON FISKALNY
        Sok jabłkowy     1 x 4,49  4,49 C
        SUMA PLN         4,49
        Rozliczenie płatności
        BLIK             4,49
        NR TRANSAKCJI    00042816
        NR PARAGONU      002018
        23.11.2026  12:34
        """, becomes: """
        ŻABKA — PUNKT TESTOWY 022
        PARAGON FISKALNY
        Sok jabłkowy     1 x 4,49  4,49 C
        SUMA PLN         4,49
        Rozliczenie płatności
        BLIK             4,49
        NR TRANSAKCJI    00042816
        NR PARAGONU      002018
        23.11.2026  12:34
        """)
    }

    func testFoodCounterBLIKWithAuthorizationCode() {
        assertReceipt("""
        BAR TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Zupa dnia       1 x 18,00  18,00 B
        SUMA PLN 18,00
        BLIK 18,00
        KOD AUTORYZACJI: 073528
        NR TRANSAKCJI: 00039157
        DATA: 2026-11-23 12:40:03
        """, becomes: """
        BAR TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Zupa dnia       1 x 18,00  18,00 B
        SUMA PLN 18,00
        BLIK 18,00
        KOD AUTORYZACJI: [REDACTED]
        NR TRANSAKCJI: 00039157
        DATA: 2026-11-23 12:40:03
        """)
    }

    func testOrlenCommaSeparatedPAN() {
        assertReceipt("""
        ORLEN — STACJA TESTOWA 031
        NIP 0001357922
        PARAGON FISKALNY
        PB95   25,000 l x 6,59     164,75 A
        SPRZEDAŻ OPODATKOWANA A   164,75
        PTU A 23%                  30,81
        SUMA PLN                  164,75
        KARTA PŁATNICZA           164,75
        NR KARTY: 4222,22222,2222
        2026-11-23 06:53
        """, becomes: """
        ORLEN — STACJA TESTOWA 031
        NIP 0001357922
        PARAGON FISKALNY
        PB95   25,000 l x 6,59     164,75 A
        SPRZEDAŻ OPODATKOWANA A   164,75
        PTU A 23%                  30,81
        SUMA PLN                  164,75
        KARTA PŁATNICZA           164,75
        NR KARTY: [REDACTED]
        2026-11-23 06:53
        """)
    }

    func testOrlenBuyerNIPAndTransactionReferenceInsideCardBlock() {
        assertReceipt("""
        ORLEN — STACJA TESTOWA 032
        PARAGON FISKALNY
        Olej napędowy  40,000 l x 6,49  259,60 A
        SUMA PLN 259,60
        KARTA PŁATNICZA: 259,60
        NR KARTY: 5555********4444
        NIP nabywcy: 000-112-23-37
        NR TRANSAKCJI: 00071042
        23.11.2026 16:12
        """, becomes: """
        ORLEN — STACJA TESTOWA 032
        PARAGON FISKALNY
        Olej napędowy  40,000 l x 6,49  259,60 A
        SUMA PLN 259,60
        KARTA PŁATNICZA: 259,60
        NR KARTY: [REDACTED]
        NIP nabywcy: 000-112-23-37
        NR TRANSAKCJI: 00071042
        23.11.2026 16:12
        """)
    }

    func testBPDotSeparatedPANAndLoyaltyReference() {
        assertReceipt("""
        BP — STACJA TESTOWA 041
        PARAGON FISKALNY
        LPG   30,000 l x 2,89  86,70 A
        PTU A 23% 16,21
        SUMA PLN 86,70
        NR KARTY: 422222222.2222
        PŁATNOŚĆ ZBLIŻENIOWA
        23-11-2026  09:15:02
        DZIĘKUJEMY
        NR KARTY LOJALNOŚCIOWEJ: 2900000004820
        """, becomes: """
        BP — STACJA TESTOWA 041
        PARAGON FISKALNY
        LPG   30,000 l x 2,89  86,70 A
        PTU A 23% 16,21
        SUMA PLN 86,70
        NR KARTY: [REDACTED]
        PŁATNOŚĆ ZBLIŻENIOWA
        23-11-2026  09:15:02
        DZIĘKUJEMY
        NR KARTY LOJALNOŚCIOWEJ: 2900000004820
        """)
    }

    func testBPDotSeparatedMaskedTailAndFiscalPadding() {
        assertReceipt("""
        BP — STACJA TESTOWA 042
        PARAGON FISKALNY
        Płyn do spryskiwaczy  1 x 19,99  19,99 A
        SUMA PLN ****19,99
        NR KARTY: ****12.34
        KWOTA: 19,99 PLN
        DATA: 23.11.2026 21:07
        """, becomes: """
        BP — STACJA TESTOWA 042
        PARAGON FISKALNY
        Płyn do spryskiwaczy  1 x 19,99  19,99 A
        SUMA PLN ****19,99
        NR KARTY: [REDACTED]
        KWOTA: 19,99 PLN
        DATA: 23.11.2026 21:07
        """)
    }

    func testPharmacyOCRLowercaseLAndProductEAN() {
        assertReceipt("""
        APTEKA TESTOWA POD PRÓBKĄ
        NIP 0002016034
        PARAGON FISKALNY
        Opatrunek jałowy  EAN 2900000443211
                          2 x 6,45  12,90 B
        PTU B 8% 0,96
        SUMA PLN 12,90
        Karta płatnicza 12,90
        VISA: 4l11 1111 1111 1111
        2026-11-23 10:46
        """, becomes: """
        APTEKA TESTOWA POD PRÓBKĄ
        NIP 0002016034
        PARAGON FISKALNY
        Opatrunek jałowy  EAN 2900000443211
                          2 x 6,45  12,90 B
        PTU B 8% 0,96
        SUMA PLN 12,90
        Karta płatnicza 12,90
        VISA: [REDACTED]
        2026-11-23 10:46
        """)
    }

    func testPharmacyOCRReplacesAnEntireDigitGroup() {
        assertReceipt("""
        APTEKA TESTOWA POD PRÓBKĄ
        PARAGON FISKALNY
        Wyrób medyczny  1 x 32,90  32,90 B
        PTU B 8%  2,44
        SUMA PLN 32,90
        NR KARTY: 6O11 llll 1111 1117
        KARTA PŁATNICZA 32,90
        23.11.2026 10:55:14
        """, becomes: """
        APTEKA TESTOWA POD PRÓBKĄ
        PARAGON FISKALNY
        Wyrób medyczny  1 x 32,90  32,90 B
        PTU B 8%  2,44
        SUMA PLN 32,90
        NR KARTY: [REDACTED]
        KARTA PŁATNICZA 32,90
        23.11.2026 10:55:14
        """)
    }

    func testRestaurantTipAndContactlessTotal() {
        assertReceipt("""
        RESTAURACJA TESTOWA POD PRÓBKĄ
        NIP 0002224442
        PARAGON FISKALNY
        Pierogi z grzybami  2 x 34,00  68,00 B
        Herbata             2 x 11,00  22,00 A
        SUMA PLN 90,00
        eService   SPRZEDAŻ ZBLIŻENIOWA
        NR KARTY: XXXX XXXX XXXX 1234
        KWOTA   90,00 PLN
        NAPIWEK  9,00 PLN
        RAZEM   99,00 PLN
        23.11.2026 19:34
        """, becomes: """
        RESTAURACJA TESTOWA POD PRÓBKĄ
        NIP 0002224442
        PARAGON FISKALNY
        Pierogi z grzybami  2 x 34,00  68,00 B
        Herbata             2 x 11,00  22,00 A
        SUMA PLN 90,00
        eService   SPRZEDAŻ ZBLIŻENIOWA
        NR KARTY: [REDACTED]
        KWOTA   90,00 PLN
        NAPIWEK  9,00 PLN
        RAZEM   99,00 PLN
        23.11.2026 19:34
        """)
    }

    func testRestaurantLargeTipAndTotalOnOneOCRLine() {
        assertReceipt("""
        RESTAURACJA TESTOWA SALA PRÓBNA
        PARAGON FISKALNY
        Kolacja grupowa  12 x 89,00  1068,00 B
        SUMA PLN 1068,00
        KARTA PŁATNICZA 1068,00
        NR KARTY: ************4444
        NAPIWEK PLN 106,80  RAZEM PLN 1174,80
        NR PARAGONU: 00315062
        """, becomes: """
        RESTAURACJA TESTOWA SALA PRÓBNA
        PARAGON FISKALNY
        Kolacja grupowa  12 x 89,00  1068,00 B
        SUMA PLN 1068,00
        KARTA PŁATNICZA 1068,00
        NR KARTY: [REDACTED]
        NAPIWEK PLN 106,80  RAZEM PLN 1174,80
        NR PARAGONU: 00315062
        """)
    }

    func testEServiceEMVAndShortTerminalFields() {
        assertReceipt("""
        eService — PUNKT TESTOWY
        POTWIERDZENIE PŁATNOŚCI
        PŁATNOŚĆ ZBLIŻENIOWA VISA
        NR KARTY: ************1234
        AID: A0000000031010
        ARQC: 9F3C2B1A0D4E5F60
        TVR: 0000000000
        TSI: E800
        ATC: 002A
        KWOTA: 24,90 PLN
        23.11.2026  13:28
        TRANSAKCJA ZAAKCEPTOWANA
        EGZEMPLARZ KLIENTA
        NR TERMINALA: T9034172
        KOD AUTORYZACJI: 05A271
        NR TRANSAKCJI: 00000714
        """, becomes: """
        eService — PUNKT TESTOWY
        POTWIERDZENIE PŁATNOŚCI
        PŁATNOŚĆ ZBLIŻENIOWA VISA
        NR KARTY: [REDACTED]
        AID: [REDACTED]
        ARQC: [REDACTED]
        TVR: [REDACTED]
        TSI: [REDACTED]
        ATC: [REDACTED]
        KWOTA: 24,90 PLN
        23.11.2026  13:28
        TRANSAKCJA ZAAKCEPTOWANA
        EGZEMPLARZ KLIENTA
        NR TERMINALA: [REDACTED]
        KOD AUTORYZACJI: [REDACTED]
        NR TRANSAKCJI: 00000714
        """)
    }

    func testPolcardOCRSplitsPANAcrossYBands() {
        assertReceipt("""
        POLCARD / FISERV — TERMINAL TESTOWY
        SPRZEDAŻ ZBLIŻENIOWA
        NR KARTY: 4111 1111
          1111
          1111
        DATA: 23.11.2026 15:58
        KWOTA: 72,60 PLN
        NR TRANSAKCJI: 002469
        """, becomes: """
        POLCARD / FISERV — TERMINAL TESTOWY
        SPRZEDAŻ ZBLIŻENIOWA
        NR KARTY: [REDACTED]
          [REDACTED]
          [REDACTED]
        DATA: 23.11.2026 15:58
        KWOTA: 72,60 PLN
        NR TRANSAKCJI: 002469
        """)
    }

    func testPePMaskedNumberAndExpiry() {
        assertReceipt("""
        PeP — TERMINAL TESTOWY
        POTWIERDZENIE TRANSAKCJI
        NR KARTY
        **** 12 34
        WAŻNA DO: 11/29
        SUMA PLN  38,00
        23-11-2026 18:51:04
        NR TRANSAKCJI 006901
        """, becomes: """
        PeP — TERMINAL TESTOWY
        POTWIERDZENIE TRANSAKCJI
        NR KARTY
        [REDACTED]
        WAŻNA DO: [REDACTED]
        SUMA PLN  38,00
        23-11-2026 18:51:04
        NR TRANSAKCJI 006901
        """)
    }

    func testWorldlineRefundPreservesSignAndOriginalReceiptNumber() {
        assertReceipt("""
        WORLDLINE — PUNKT TESTOWY
        POTWIERDZENIE ZWROTU
        MASTERCARD
        NR KARTY: 5555-5555-5555-4444
        NR PARAGONU: 00009127
        KWOTA ZWROTU: -149,90 PLN
        DATA: 2026-11-23 14:09:05
        NR TRANSAKCJI: 00081390
        KOD AUTORYZACJI: 021593
        ZWROT ZAAKCEPTOWANY
        """, becomes: """
        WORLDLINE — PUNKT TESTOWY
        POTWIERDZENIE ZWROTU
        MASTERCARD
        NR KARTY: [REDACTED]
        NR PARAGONU: 00009127
        KWOTA ZWROTU: -149,90 PLN
        DATA: 2026-11-23 14:09:05
        NR TRANSAKCJI: 00081390
        KOD AUTORYZACJI: [REDACTED]
        ZWROT ZAAKCEPTOWANY
        """)
    }

    func testBakeryUnlabelledThirteenDigitPAN() {
        assertReceipt("""
        PIEKARNIA TESTOWA
        PARAGON FISKALNY
        Rogalik maślany   3 x 3,70  11,10 C
        PTU C 5% 0,53
        SUMA PLN 11,10
        NR PARAGONU 001159
        POTWIERDZENIE PŁATNOŚCI
        4222222222222
        23.11.2026 06:25
        """, becomes: """
        PIEKARNIA TESTOWA
        PARAGON FISKALNY
        Rogalik maślany   3 x 3,70  11,10 C
        PTU C 5% 0,53
        SUMA PLN 11,10
        NR PARAGONU 001159
        POTWIERDZENIE PŁATNOŚCI
        [REDACTED]
        23.11.2026 06:25
        """)
    }

    func testHotelAmexWithFourSixFiveGrouping() {
        assertReceipt("""
        HOTEL TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Nocleg    1 x 248,00  248,00 B
        PTU B 8% 18,37
        SUMA PLN 248,00
        AMEX: 3782 822463 10005
        KARTA PŁATNICZA 248,00 PLN
        NR PARAGONU 003822
        2026-11-23 08:21
        """, becomes: """
        HOTEL TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Nocleg    1 x 248,00  248,00 B
        PTU B 8% 18,37
        SUMA PLN 248,00
        AMEX: [REDACTED]
        KARTA PŁATNICZA 248,00 PLN
        NR PARAGONU 003822
        2026-11-23 08:21
        """)
    }

    func testHotelDiscoverWithDateAndTimeInTerminalBlock() {
        assertReceipt("""
        HOTEL TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Śniadanie  2 x 39.00  78.00 B
        SUMA PLN  78.00
        KARTA DISCOVER: 6011-1111-1111-1117
        DATA: 23/11/2026 09:11:50
        NR PARAGONU: 00002016
        KWOTA: 78.00 PLN
        """, becomes: """
        HOTEL TESTOWY POD PRÓBKĄ
        PARAGON FISKALNY
        Śniadanie  2 x 39.00  78.00 B
        SUMA PLN  78.00
        KARTA DISCOVER: [REDACTED]
        DATA: 23/11/2026 09:11:50
        NR PARAGONU: 00002016
        KWOTA: 78.00 PLN
        """)
    }

    func testPharmacyCashPreservesCRLFAndDecomposedText() {
        assertReceipt(
            "APTEKA TESTOWA\r\nPARAGON FISKALNY\r\nOpatrunek jałowy  1 x 5,40  5,40 B\r\n" +
            "Warstwowy wacik  1 x 3,10  3,10 A\r\nSUMA PLN 8,50\r\n" +
            "Płatnos\u{0301}c\u{0301} gotówką 10,00\r\nReszta 1,50\r\n",
            becomes:
                "APTEKA TESTOWA\r\nPARAGON FISKALNY\r\nOpatrunek jałowy  1 x 5,40  5,40 B\r\n" +
                "Warstwowy wacik  1 x 3,10  3,10 A\r\nSUMA PLN 8,50\r\n" +
                "Płatnos\u{0301}c\u{0301} gotówką 10,00\r\nReszta 1,50\r\n"
        )
    }

    func testOCRTransactionLabelDoesNotProtectWrappedPAN() {
        // On a skewed slip, Vision attaches the neighbouring label to the PAN.
        assertReceipt("""
        PeP — TERMINAL TESTOWY
        POTWIERDZENIE PŁATNOŚCI
        KARTA VISA
        NR TRANSAKCJI: 41111111
                       11111111
        NR PARAGONU: 00063518
        KWOTA: 49,90 PLN
        23.11.2026 17:31
        """, becomes: """
        PeP — TERMINAL TESTOWY
        POTWIERDZENIE PŁATNOŚCI
        KARTA VISA
        NR TRANSAKCJI: [REDACTED]
                       [REDACTED]
        NR PARAGONU: 00063518
        KWOTA: 49,90 PLN
        23.11.2026 17:31
        """)
    }

    func testOCRLoyaltyLabelDoesNotProtectDottedPAN() {
        // OCR merged the loyalty heading with the card value printed beside it.
        assertReceipt("""
        LIDL — SKLEP TESTOWY 015
        PARAGON FISKALNY
        Sok pomidorowy  1 x 5,39  5,39 C
        PTU C 5%  0,26
        SUMA PLN 5,39
        Karta lojalnościowa: 422222222.2222
        NR TRANSAKCJI 00049531
        23.11.2026 08:54
        """, becomes: """
        LIDL — SKLEP TESTOWY 015
        PARAGON FISKALNY
        Sok pomidorowy  1 x 5,39  5,39 C
        PTU C 5%  0,26
        SUMA PLN 5,39
        Karta lojalnościowa: [REDACTED]
        NR TRANSAKCJI 00049531
        23.11.2026 08:54
        """)
    }

    func testLuhnCollisionOnInternalEANIsConservativelyRedacted() {
        // Accepted false positive: this synthetic internal EAN passes both
        // checksums. A label alone cannot exempt a PAN-shaped Luhn match.
        assertReceipt("""
        SKLEP TESTOWY
        PARAGON FISKALNY
        Wyrób na wagę  EAN 2900000000025
                       0,500 x 8,00  4,00 C
        SUMA PLN 4,00
        Karta płatnicza 4,00
        NR KARTY: ************1234
        """, becomes: """
        SKLEP TESTOWY
        PARAGON FISKALNY
        Wyrób na wagę  EAN [REDACTED]
                       0,500 x 8,00  4,00 C
        SUMA PLN 4,00
        Karta płatnicza 4,00
        NR KARTY: [REDACTED]
        """)
    }

    private func assertReceipt(
        _ input: String,
        becomes expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = PANRedactor.redact(input)
        if !actual.utf8.elementsEqual(expected.utf8) {
            XCTFail("Expected exact receipt:\n\(expected)\n\nActual receipt:\n\(actual)", file: file, line: line)
        }
    }
}
