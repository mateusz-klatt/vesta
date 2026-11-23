import XCTest
import CoreGraphics
import Foundation
import HTTPTypes
import OpenAPIRuntime
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
        // Label line + 3 following lines are the block; line 5 is outside.
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
}

// MARK: - Line ordering

final class ReceiptLineOrderingTests: XCTestCase {
    private func frag(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.02) -> TextFragment {
        TextFragment(text: text, box: CGRect(x: x, y: y, width: w, height: h))
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

    func testDropsBlankFragments() {
        XCTAssertEqual(ReceiptLineOrdering.lines(from: [frag("  ", x: 0, y: 0.5)]), [])
        XCTAssertEqual(ReceiptLineOrdering.lines(from: []), [])
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
  "merchant_token_hit":true,"date_distance":0,"candidate_token":"tok-1234567890123456789012345678901234567"}]}
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

final class ReceiptsClientTests: XCTestCase {
    func testParseDecodesDraftAndCandidates() async throws {
        let api = APIClient(transport: StubTransport { request in
            XCTAssertEqual(request.path, "/api/budget/receipts/parse-text")
            return (200, body(sampleParseJSON))
        })
        let result = try await api.parseReceiptText("BIEDRONKA")
        XCTAssertEqual(result.receiptId, sampleReceiptID)
        XCTAssertEqual(result.draft.lines.count, 2)
        XCTAssertEqual(result.draft.totalAmount, "7.98")
        XCTAssertEqual(result.candidates.first?.entryReference, "tx1")
    }

    func testParseDisabledMapped() async {
        let api = APIClient(transport: StubTransport { _ in (404, body(#"{"ok":false,"error":"budget_receipts_disabled"}"#)) })
        await assertReceiptError(try await api.parseReceiptText("x"), .disabled)
    }

    func testParseForbiddenWithEmptyBody() async {
        let api = APIClient(transport: StubTransport { _ in (403, nil) })
        await assertReceiptError(try await api.parseReceiptText("x"), .forbidden)
    }

    func testParseQuotaMapped() async {
        let api = APIClient(transport: StubTransport { _ in (413, body(#"{"ok":false,"error":"budget_receipt_quota_exceeded"}"#)) })
        await assertReceiptError(try await api.parseReceiptText("x"), .draftQuota)
    }

    func testConfirmWireBodyHasEveryKeyIncludingNulls() async throws {
        let transport = CapturingTransport(status: 409, body: #"{"ok":false,"error":"budget_receipt_stale_source"}"#)
        let api = APIClient(transport: transport)
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
        let api = APIClient(transport: StubTransport { _ in (200, body(#"{"ok":true,"deleted":true}"#)) })
        try await api.deleteReceipt(id: sampleReceiptID, expectedVersion: 1)
    }
}

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
        XCTAssertEqual(request.lines.map(\.netLineTotal), ["3.49", "4.49"])
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
        p.draft.rawShopName = signed
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
    enum Call: Equatable { case parse(String), confirm(String?), delete(String, Int) }
    private(set) var calls: [Call] = []
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

    func parseReceiptText(_ text: String) async throws -> ReceiptParseResult {
        calls.append(.parse(text))
        if holdParse {
            holdParse = false
            await withCheckedContinuation { parseGate = $0 }
        }
        if let parseError { throw parseError }
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8))
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        calls.append(.confirm(request.link?.entryReference))
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8)).draft
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        calls.append(.delete(id, expectedVersion))
        if holdDelete {
            holdDelete = false
            await withCheckedContinuation { deleteGate = $0 }
        }
        if let deleteError { throw deleteError }
    }
}

struct StubRecognizer: ReceiptTextRecognizing {
    let fragments: [TextFragment]
    func recognize(_: CGImage) async throws -> [TextFragment] { fragments }
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
        var origin = "https://a.example"
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor) { origin }
        flow.useText("A")
        await flow.send()
        await api.failDelete(.api(.offline))
        await flow.abandon()                       // A's draft stays queued
        await api.failDelete(nil)
        origin = "https://b.example"
        let onB = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor) { origin }
        await onB.abandon()
        var deletes = await api.calls.filter { if case .delete = $0 { true } else { false } }
        XCTAssertEqual(deletes.count, 1)           // nothing sent to B
        let queued = await janitor.pendingCount
        XCTAssertEqual(queued, 1)
        origin = "https://a.example"
        let backOnA = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []), janitor: janitor) { origin }
        await backOnA.abandon()
        deletes = await api.calls.filter { if case .delete = $0 { true } else { false } }
        XCTAssertEqual(deletes.count, 2)
        let drained = await janitor.pendingCount
        XCTAssertEqual(drained, 0)
    }

    func testCancelDuringCleanupSendsNoText() async {
        let api = MockReceiptsAPI()
        let janitor = ReceiptDraftJanitor()
        await janitor.enqueue(id: "old", version: 1, server: AppConfig.serverURL.absoluteString)
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

    func testOverlappingSendsIssueOneRequest() async {
        let api = MockReceiptsAPI()
        await api.holdNextParse()
        let flow = ReceiptFlow(api: api, recognizer: StubRecognizer(fragments: []))
        flow.useText("A")
        let first = Task { await flow.send() }
        while await api.calls.isEmpty { await Task.yield() }
        await flow.send()                          // double tap: ignored while busy
        await api.releaseParse()
        await first.value
        let parses = await api.calls.filter { if case .parse = $0 { true } else { false } }
        XCTAssertEqual(parses.count, 1)
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
