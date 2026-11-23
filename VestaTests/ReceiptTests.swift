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

    func testConfirmSendsEveryKeyIncludingNulls() async throws {
        let api = APIClient(transport: StubTransport { request in
            XCTAssertEqual(request.path, "/api/budget/receipts/confirm")
            return (409, body(#"{"ok":false,"error":"budget_receipt_stale_source"}"#))
        })
        let parsed = try JSONDecoder().decode(ReceiptParseResult.self, from: body(sampleParseJSON))
        var form = ReceiptForm(draft: parsed.draft, candidates: parsed.candidates)
        form.time = ""
        let request = form.request(receiptID: parsed.receiptId, version: parsed.version, candidates: parsed.candidates)
        await assertReceiptError(try await api.confirmReceipt(request), .staleCandidate)
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
        XCTAssertEqual(form.candidateRef, "tx1")
        XCTAssertNil(form.mismatch)
        XCTAssertTrue(form.isValid)
    }

    func testRequestCarriesLinkAndCanonicalFields() throws {
        let p = try parsed()
        let request = ReceiptForm(draft: p.draft, candidates: p.candidates)
            .request(receiptID: p.receiptId, version: p.version, candidates: p.candidates)
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
        XCTAssertNil(form.request(receiptID: p.receiptId, version: 1, candidates: p.candidates).link)
    }

    func testMismatchAndValidation() throws {
        let p = try parsed()
        var form = ReceiptForm(draft: p.draft, candidates: p.candidates)
        form.total = "8.00"
        XCTAssertEqual(form.mismatch, Decimal(string: "-0.02"))
        XCTAssertFalse(form.isValid)
        form.total = "7,98"                        // comma from the keyboard
        XCTAssertNil(form.mismatch)
        XCTAssertEqual(form.request(receiptID: p.receiptId, version: 1, candidates: []).totalAmount, "7.98")
        form.nip = "123"
        XCTAssertFalse(form.isValid)
        form.nip = ""
        form.time = "25:00"
        XCTAssertFalse(form.isValid)
    }

    func testDecimalNeverAcceptsGarbage() {
        XCTAssertNil(ReceiptForm.decimal("1e3"))
        XCTAssertNil(ReceiptForm.decimal("abc"))
        XCTAssertEqual(ReceiptForm.decimal("12,50"), Decimal(string: "12.50"))
    }
}

// MARK: - Flow

actor MockReceiptsAPI: ReceiptsAPI {
    enum Call: Equatable { case parse(String), confirm(String?), delete(String, Int) }
    private(set) var calls: [Call] = []
    private var parseError: ReceiptError?

    func failParse(_ error: ReceiptError) { parseError = error }

    func parseReceiptText(_ text: String) async throws -> ReceiptParseResult {
        calls.append(.parse(text))
        if let parseError { throw parseError }
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8))
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        calls.append(.confirm(request.link?.entryReference))
        return try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8)).draft
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        calls.append(.delete(id, expectedVersion))
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
        XCTAssertEqual(flow.form.candidateRef, "tx1")
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
