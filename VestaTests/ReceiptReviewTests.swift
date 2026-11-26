import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

private enum ReviewFixtures {
    static let origin = URL(string: "https://hestia.example")!
    static let ownerKey = String(repeating: "b", count: 43)
    static let ids = [
        "00000000-0000-0000-0000-000000000001",
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000003",
        "00000000-0000-0000-0000-000000000004",
    ]

    static func summary(_ index: Int = 0, shop: String? = "Shop", chain: String? = nil, version: Int = 1) -> ImportedReceiptSummary {
        .init(receiptId: ids[index], rawShopName: shop, chainKey: chain, version: version)
    }

    static func detail(_ index: Int = 0, shop: String? = "Shop", version: Int = 1) -> ReceiptDetail {
        .init(receiptId: ids[index], rawShopName: shop, version: version)
    }

    static func candidate(_ index: Int = 0, strength: ReceiptCandidate.MatchStrengthPayload = .nip) -> ReceiptCandidate {
        .init(accountId: "account", entryReference: "entry-\(index)", matchStrength: strength,
              candidateToken: "candidate-\(index)")
    }

    static func capabilities(matching: Bool = true) -> Capabilities {
        var permissions = ReceiptReviewGate.requiredPermissions
        if matching { permissions.insert(.budgetReceiptsMatch) }
        return Capabilities(user: "u", ownBudget: .init(
            permissions: permissions, canView: false, canUseReceipts: true, canManageDevices: true
        ))
    }

    static func device(matching: Bool = true, provenance: DeviceTokenProvenance = .exchanged) -> StoredReceiptDeviceToken {
        var permissions = ReceiptReviewGate.requiredPermissions
        if matching { permissions.insert(.budgetReceiptsMatch) }
        return .init(server: origin, provenance: provenance, actor: "u", owner: "u", ownerKey: ownerKey,
                     issuedPermissions: permissions.map(\.rawValue), lastUsableCeiling: permissions.map(\.rawValue),
                     deviceScope: .device, credential: fakeDeviceToken)
    }

    static var features: ServerFeatures {
        .init(authContract: 2, features: [.capabilities, .deviceExchange], qrOrigin: nil, isLegacy: false)
    }

    static var scope: ReceiptSessionScope {
        .init(origin: origin, actor: "u", ownerKey: ownerKey, credential: fakeDeviceToken)
    }

    static func candidateObject(strength: String = "nip") -> [String: Any] {
        [
            "account_id": "account", "entry_reference": "entry-0", "amount": "12.34", "currency": "PLN",
            "credit_debit_indicator": "DBIT", "transaction_date": "2026-11-22", "booking_date": NSNull(),
            "value_date": NSNull(), "merchant_token_hit": true, "match_strength": strength,
            "date_distance": 0, "candidate_token": "candidate-0",
        ]
    }

    static func summaryObject(_ index: Int = 0, hints: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "receipt_id": ids[index], "shop_id": NSNull(), "chain_key": NSNull(), "raw_shop_name": "Shop",
            "raw_nip": NSNull(), "receipt_kind": "purchase", "receipt_date": "2026-11-22", "receipt_time": NSNull(),
            "total_amount": "12.34", "currency": "PLN", "payment_method": "card", "status": "imported",
            "source_kind": "email", "linked": false, "linked_account_id": NSNull(), "linked_entry_ref": NSNull(),
            "version": 1, "created_at": 0, "updated_at": 0, "image_available": false,
            "image_expires_at": NSNull(), "raw_text_expires_at": NSNull(), "math_delta": NSNull(),
        ]
        if hints {
            object["gateway_status"] = "registered"
            object["payee_host"] = "hestia.example"
            object["has_document"] = false
        }
        return object
    }

    static func detailObject(_ index: Int = 0, hints: Bool = false) -> [String: Any] {
        var object = summaryObject(index, hints: hints)
        object["lines"] = [[
            "line_no": 1, "line_kind": "item", "raw_name": "Item", "raw_name_key": "item",
            "ptu_code": NSNull(), "quantity": "1", "raw_unit": NSNull(), "unit_price_raw": "12.34",
            "gross_line_total": "12.34", "discount_amount": "0", "net_line_total": "12.34",
        ]]
        return object
    }

    static func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}

private actor ReviewResponseGate {
    private(set) var isWaiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else {
                isWaiting = true
                self.continuation = continuation
            }
        }
    }

    func release() {
        released = true
        isWaiting = false
        continuation?.resume()
        continuation = nil
    }
}

private actor MockReceiptReviewAPI: ReceiptReviewAPI {
    enum Call: Equatable {
        case list(String?)
        case detail(String)
        case confirm(String, Int, String?)
    }

    private(set) var calls: [Call] = []
    private(set) var confirms: [ReceiptConfirmRequest] = []
    private var pages: [String: ReceiptListPage] = [:]
    private var details: [String: Result<ReceiptDetailResult, ReceiptError>] = [:]
    private var confirmErrors: [String: ReceiptError] = [:]
    private var detailGates: [String: ReviewResponseGate] = [:]
    private var confirmGates: [String: ReviewResponseGate] = [:]
    var listError: ReceiptError?

    func setPage(cursor: String?, receipts: [ImportedReceiptSummary], next: String?) {
        pages[cursor ?? "first"] = .init(receipts: receipts, nextCursor: next)
    }

    func setDetail(_ receipt: ReceiptDetail, candidates: [ReceiptCandidate]? = nil) {
        details[receipt.receiptId] = .success(.init(receipt: receipt, candidates: candidates))
    }

    func setDetailError(_ id: String, _ error: ReceiptError) { details[id] = .failure(error) }
    func setConfirmError(_ id: String, _ error: ReceiptError?) { confirmErrors[id] = error }
    func holdDetail(_ id: String, gate: ReviewResponseGate) { detailGates[id] = gate }
    func holdConfirm(_ id: String, gate: ReviewResponseGate) { confirmGates[id] = gate }

    func listImportedReceipts(cursor: String?, scope: ReceiptSessionScope) async throws -> ReceiptListPage {
        calls.append(.list(cursor))
        if let listError { throw listError }
        return pages[cursor ?? "first"] ?? .init(receipts: [])
    }

    func receiptDetail(id: String, scope: ReceiptSessionScope) async throws -> ReceiptDetailResult {
        calls.append(.detail(id))
        if let gate = detailGates[id] { await gate.wait() }
        if let result = details[id] { return try result.get() }
        let components = id.split(separator: "-")
        let index = components.last.flatMap { Int($0) }.map { max(0, $0 - 1) } ?? 0
        return .init(receipt: ReviewFixtures.detail(index), candidates: nil)
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail {
        calls.append(.confirm(request.receiptId, request.expectedVersion, request.link?.entryReference))
        confirms.append(request)
        if let gate = confirmGates[request.receiptId] { await gate.wait() }
        if let error = confirmErrors[request.receiptId] { throw error }
        let index = ReviewFixtures.ids.firstIndex(of: request.receiptId) ?? 0
        var detail = ReviewFixtures.detail(index, version: request.expectedVersion + 1)
        detail.status = .confirmed
        return detail
    }
}

final class ReceiptReviewMappingTests: XCTestCase {
    func testOptionalHintsMayBeAbsentOrPresent() throws {
        let absent = try JSONDecoder().decode(
            ImportedReceiptSummary.self, from: ReviewFixtures.data(ReviewFixtures.summaryObject())
        )
        XCTAssertNil(absent.gatewayStatus)
        XCTAssertNil(absent.payeeHost)
        XCTAssertNil(absent.hasDocument)

        let present = try JSONDecoder().decode(
            ReceiptDetail.self, from: ReviewFixtures.data(ReviewFixtures.detailObject(hints: true))
        )
        XCTAssertEqual(present.gatewayStatus, .registered)
        XCTAssertEqual(present.payeeHost, "hestia.example")
        XCTAssertEqual(present.hasDocument, false)
    }

    func testRequiredNullableKeysRejectMissingAndAcceptNull() throws {
        var summary = ReviewFixtures.summaryObject()
        summary.removeValue(forKey: "raw_nip")
        XCTAssertThrowsError(try JSONDecoder().decode(
            ImportedReceiptSummary.self, from: ReviewFixtures.data(summary)
        ))

        var list = try XCTUnwrap(JSONSerialization.jsonObject(with: ReviewFixtures.data([
            "receipts": [ReviewFixtures.summaryObject()], "next_cursor": NSNull(),
        ])) as? [String: Any])
        list.removeValue(forKey: "next_cursor")
        XCTAssertThrowsError(try JSONDecoder().decode(ReceiptListPage.self, from: ReviewFixtures.data(list)))
    }

    func testLegacyScanMayOmitNullableFieldsAndCandidateStrength() throws {
        var detail = ReviewFixtures.detailObject()
        detail["status"] = "draft"
        detail["source_kind"] = "live_text"
        detail.removeValue(forKey: "linked_entry_ref")
        var lines = try XCTUnwrap(detail["lines"] as? [[String: Any]])
        lines[0].removeValue(forKey: "raw_unit")
        detail["lines"] = lines
        var candidate = ReviewFixtures.candidateObject()
        candidate.removeValue(forKey: "transaction_date")
        candidate.removeValue(forKey: "match_strength")
        let result = try JSONDecoder().decode(ReceiptParseResult.self, from: ReviewFixtures.data([
            "receipt_id": ReviewFixtures.ids[0], "version": 1,
            "draft": detail, "candidates": [candidate], "warnings": [],
        ]))
        XCTAssertNil(result.draft.linkedEntryRef)
        XCTAssertNil(result.draft.lines.first?.rawUnit)
        XCTAssertEqual(result.candidates.first?.matchStrength, ReceiptCandidate.MatchStrengthPayload.none)
    }

    func testPreselectsOnlyExactlyOneStrongCandidate() {
        for strength in [ReceiptCandidate.MatchStrengthPayload.nip, .distinctive] {
            let candidate = ReviewFixtures.candidate(strength: strength)
            XCTAssertEqual(ReceiptReviewStore.preselectedCandidate(from: [candidate]), candidate)
        }
        for strength in [ReceiptCandidate.MatchStrengthPayload.generic, .none] {
            XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: [ReviewFixtures.candidate(strength: strength)]))
        }
        XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: []))
        XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: [
            ReviewFixtures.candidate(0, strength: .nip), ReviewFixtures.candidate(1, strength: .distinctive),
        ]))
    }
}

@MainActor
final class ReceiptReviewStoreTests: XCTestCase {
    private let scope = ReviewFixtures.scope

    func testListPaginatesFiltersAndGroupsByMerchant() async {
        let api = MockReceiptReviewAPI()
        await api.setPage(cursor: nil, receipts: [
            ReviewFixtures.summary(0, shop: "Biedronka"),
            ReviewFixtures.summary(1, shop: "Variant", chain: "chain"),
        ], next: "next")
        await api.setPage(cursor: "next", receipts: [
            ReviewFixtures.summary(2, shop: "biedronka"),
            ReviewFixtures.summary(3, shop: "Other", chain: "chain"),
            ReviewFixtures.summary(0, shop: "Duplicate"),
        ], next: nil)
        let store = ReceiptReviewStore(api: api, scope: scope)

        await store.load()

        XCTAssertEqual(store.receipts.map(\.receiptId), [
            ReviewFixtures.ids[0], ReviewFixtures.ids[1], ReviewFixtures.ids[2], ReviewFixtures.ids[3],
        ])
        XCTAssertEqual(store.groups.map(\.name), ["Biedronka", "Variant"])
        XCTAssertEqual(store.groups.map { $0.receipts.count }, [2, 2])
        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .list("next")])
    }

    func testSingleConfirmUsesPreselectedLinkAndExpectedVersion() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail(version: 7), candidates: [ReviewFixtures.candidate()])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        XCTAssertEqual(store.selectedCandidate?.entry, "entry-0")
        await store.confirmSelected()

        let confirms = await api.confirms
        let request = try XCTUnwrap(confirms.first)
        XCTAssertEqual(request.expectedVersion, 7)
        XCTAssertEqual(request.link?.entryReference, "entry-0")
        XCTAssertEqual(request.link?.candidateToken, "candidate-0")
        XCTAssertTrue(store.receipts.isEmpty)
        XCTAssertEqual(store.outcomes.first?.status, .confirmed)
    }

    func testSingleConfirmWithoutMatchPermissionSendsNull() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail(version: 9), candidates: [ReviewFixtures.candidate()])
        let store = ReceiptReviewStore(api: api, scope: scope, allowsMatching: { false })
        await store.load()
        await store.select(summary)

        XCTAssertFalse(store.canMatchReceipts)
        XCTAssertTrue(store.candidates.isEmpty)
        XCTAssertNil(store.selectedCandidate)
        store.selectCandidate(ReviewFixtures.candidate())
        XCTAssertNil(store.selectedCandidate)
        await store.confirmSelected()

        let confirms = await api.confirms
        let request = try XCTUnwrap(confirms.first)
        XCTAssertNil(request.link)
        XCTAssertEqual(request.expectedVersion, 9)
        XCTAssertFalse(ReceiptReviewGate.allowsMatching(
            ReviewFixtures.device(matching: false), capabilities: ReviewFixtures.capabilities(matching: false)
        ))
    }

    func testBulkConfirmIsSequentialCASAndReportsMixedOutcomes() async throws {
        let api = MockReceiptReviewAPI()
        let receipts = (0...2).map { ReviewFixtures.summary($0, shop: "Shop", version: 11 + $0) }
        await api.setPage(cursor: nil, receipts: receipts, next: nil)
        for index in 0...2 {
            await api.setDetail(ReviewFixtures.detail(index, version: 11 + index),
                                candidates: [ReviewFixtures.candidate(index)])
        }
        await api.setConfirmError(ReviewFixtures.ids[1], .versionConflict)
        await api.setConfirmError(ReviewFixtures.ids[2], .alreadySubmitted)
        let firstGate = ReviewResponseGate()
        await api.holdConfirm(ReviewFixtures.ids[0], gate: firstGate)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()

        let bulk = Task { await store.confirmMerchant(store.groups[0]) }
        try await waitUntil("first merchant confirm is held") { await firstGate.isWaiting }
        var calls = await api.calls
        XCTAssertEqual(calls, [
            .list(nil), .detail(ReviewFixtures.ids[0]), .confirm(ReviewFixtures.ids[0], 11, nil),
        ])
        await firstGate.release()
        await bulk.value

        calls = await api.calls
        XCTAssertEqual(calls, [
            .list(nil),
            .detail(ReviewFixtures.ids[0]), .confirm(ReviewFixtures.ids[0], 11, nil),
            .detail(ReviewFixtures.ids[1]), .confirm(ReviewFixtures.ids[1], 12, nil),
            .detail(ReviewFixtures.ids[2]), .confirm(ReviewFixtures.ids[2], 13, nil),
        ])
        XCTAssertEqual(store.outcomes.map(\.status), [.confirmed, .failed, .alreadySubmitted])
        XCTAssertEqual(store.outcomes.map(\.code), ["confirmed", "budget_receipt_conflict", "already_submitted"])
        XCTAssertEqual(store.receipts.map(\.receiptId), [ReviewFixtures.ids[1]])
        let confirms = await api.confirms
        XCTAssertTrue(confirms.allSatisfy { $0.link == nil })
    }

    func testBulkSkipsReceiptsConfirmedLinkedOrChangedSinceListing() async throws {
        let api = MockReceiptReviewAPI()
        let receipts = (0...3).map { ReviewFixtures.summary($0, version: 3) }
        await api.setPage(cursor: nil, receipts: receipts, next: nil)
        var confirmed = ReviewFixtures.detail(0, version: 9)
        confirmed.status = .confirmed
        confirmed.linked = true
        await api.setDetail(confirmed)
        var linked = ReviewFixtures.detail(1, version: 5)
        linked.linked = true
        await api.setDetail(linked)
        await api.setDetail(ReviewFixtures.detail(2, shop: "Different merchant", version: 4))
        await api.setDetail(ReviewFixtures.detail(3, version: 3))
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.confirmMerchant(try XCTUnwrap(store.groups.first))

        let confirms = await api.confirms
        XCTAssertEqual(confirms.map(\.receiptId), [ReviewFixtures.ids[3]])
        let request = try XCTUnwrap(confirms.first)
        XCTAssertNil(request.lines)
        XCTAssertNil(request.rawShopName)
        XCTAssertNil(request.rawNip)
        XCTAssertEqual(store.outcomes.map(\.status), [.alreadySubmitted, .failed, .failed, .confirmed])
        XCTAssertEqual(store.outcomes[2].code, "budget_receipt_conflict")
    }

    func testInvoiceWithNoLinesGetsOneSummaryLine() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        var invoice = ReviewFixtures.detail()
        invoice.documentKind = .invoice
        invoice.lines = []
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(invoice)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)
        await store.confirmSelected()

        let confirms = await api.confirms
        let lines = try XCTUnwrap(confirms.first?.lines)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.lineKind, .other)
        XCTAssertEqual(lines.first?.netLineTotal, invoice.totalAmount)
    }

    func testClearDropsLateConfirmFailure() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail())
        await api.setConfirmError(summary.receiptId, .versionConflict)
        let gate = ReviewResponseGate()
        await api.holdConfirm(summary.receiptId, gate: gate)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        let confirmation = Task { await store.confirmSelected() }
        try await waitUntil("confirm response is held") { await gate.isWaiting }
        store.clear()
        await gate.release()
        await confirmation.value

        XCTAssertTrue(store.isCleared)
        XCTAssertTrue(store.outcomes.isEmpty)
        XCTAssertNil(store.failure)
    }

    func testClearDropsLateDetailResponse() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail(), candidates: [ReviewFixtures.candidate()])
        let gate = ReviewResponseGate()
        await api.holdDetail(summary.receiptId, gate: gate)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()

        let selection = Task { await store.select(summary) }
        try await waitUntil("detail response is held") { await gate.isWaiting }
        store.clear()
        await gate.release()
        await selection.value

        XCTAssertTrue(store.isCleared)
        XCTAssertNil(store.detail)
        XCTAssertTrue(store.receipts.isEmpty)
        XCTAssertTrue(store.candidates.isEmpty)
    }
}

@MainActor
private final class ReviewAppFixture {
    let mock = MockHestiaAPI()
    let review = MockReceiptReviewAPI()
    let pairingAPI = ReviewPairingStub()
    let tokens: MemoryDeviceTokenStore
    let pairing: ReceiptPairing
    let session: CredentialSessionStore
    let app: AppState

    init(enabled: Bool = true, matching: Bool = true, provenance: DeviceTokenProvenance = .exchanged) throws {
        let device = ReviewFixtures.device(matching: matching, provenance: provenance)
        tokens = MemoryDeviceTokenStore(device)
        session = try testCredentialSessionStore(origin: ReviewFixtures.origin, token: "session-token")
        pairing = ReceiptPairing(api: pairingAPI, store: tokens, serverURL: { ReviewFixtures.origin })
        app = AppState(api: mock, receiptPairing: pairing, sessionStore: session, events: { AsyncStream { $0.finish() } })
        app.receiptReviewEnabled = enabled
    }

    func connect() async {
        await mock.setFeatures(ReviewFixtures.features)
        await mock.setCapabilities(ReviewFixtures.capabilities())
        await mock.setReceiptReviewStub(review)
        await review.setPage(cursor: nil, receipts: [ReviewFixtures.summary()], next: nil)
        await app.connect()
    }
}

private actor ReviewPairingStub: DevicePairingAPI {
    func exchange(session: BoundSession, deviceName: String, priorToken: ReceiptDeviceToken?) async throws -> ExchangedDeviceToken {
        let actor = session.actor ?? "u"
        return .init(credential: fakeDeviceToken, scope: .device, actor: actor, owner: actor,
                     ownerKey: ReviewFixtures.ownerKey,
                     issuedPermissions: [
                        Permission.budgetReceiptsAdd.rawValue, Permission.budgetReceiptsView.rawValue,
                        Permission.budgetReceiptsEdit.rawValue,
                        Permission.budgetReceiptsMatch.rawValue,
                     ])
    }

    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        throw DevicePairingError.redeemFailed
    }

    func login(username: String, password: String, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        throw DevicePairingError.redeemFailed
    }

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {}
}

@MainActor
final class ReceiptReviewGateTests: XCTestCase {
    func testEntryRequiresFlagCapabilitiesAndExchangedToken() async throws {
        let disabled = try ReviewAppFixture(enabled: false)
        await disabled.connect()
        XCTAssertFalse(AppConfig.receiptReviewEnabled)
        XCTAssertFalse(AppConfig.receiptReviewEnabledForBuild)
        XCTAssertNil(disabled.app.receiptReviewAPI)
        XCTAssertNil(disabled.app.makeReceiptReviewStore())
        let disabledCalls = await disabled.review.calls
        XCTAssertEqual(disabledCalls, [])

        XCTAssertFalse(ReceiptReviewGate.allowsDevice(
            ReviewFixtures.device(provenance: .legacyPasswordLogin), origin: ReviewFixtures.origin, actor: "u"
        ))

        let noMatch = try ReviewAppFixture(matching: false)
        await noMatch.connect()
        let store = try XCTUnwrap(noMatch.app.makeReceiptReviewStore())
        XCTAssertNotNil(noMatch.app.receiptReviewAPI)
        XCTAssertFalse(store.canMatchReceipts)
    }

    func test401And403TearDownAndClearReceipts() async throws {
        for error in [ReceiptError.api(.unauthorized), .forbidden] {
            let fixture = try ReviewAppFixture()
            await fixture.connect()
            let store = try XCTUnwrap(fixture.app.makeReceiptReviewStore())
            await store.load()
            XCTAssertEqual(store.receipts.count, 1)
            await fixture.review.setDetailError(ReviewFixtures.ids[0], error)

            await store.select(ReviewFixtures.summary())

            XCTAssertTrue(store.isCleared)
            XCTAssertTrue(store.receipts.isEmpty)
            XCTAssertNil(store.detail)
            let calls = await fixture.review.calls
            await store.load()
            let callsAfterRetry = await fixture.review.calls
            XCTAssertEqual(callsAfterRetry, calls)
        }
    }

    func testSessionSwitchesDropLateResponses() async throws {
        for scenario in ["sign out", "account", "origin"] {
            let fixture = try ReviewAppFixture()
            await fixture.connect()
            let summary = ReviewFixtures.summary()
            await fixture.review.setDetail(ReviewFixtures.detail(), candidates: [ReviewFixtures.candidate()])
            let gate = ReviewResponseGate()
            await fixture.review.holdDetail(summary.receiptId, gate: gate)
            let store = try XCTUnwrap(fixture.app.makeReceiptReviewStore())
            await store.load()
            let selection = Task { await store.select(summary) }
            try await waitUntil("held review response before \(scenario)") { await gate.isWaiting }

            switch scenario {
            case "sign out":
                let signedOut = await fixture.app.signOut()
                XCTAssertTrue(signedOut)
            case "account": await fixture.app.login(user: "other", password: "fake-password")
            case "origin": XCTAssertTrue(fixture.app.saveAndConnect("https://hestia.example:8443"))
            default: XCTFail("Unknown scenario")
            }
            XCTAssertTrue(store.isCleared, scenario)
            await gate.release()
            await selection.value

            XCTAssertNil(store.detail, scenario)
            XCTAssertTrue(store.receipts.isEmpty, scenario)
            XCTAssertTrue(store.candidates.isEmpty, scenario)
        }
    }
}

@MainActor
final class ReceiptReviewClientTests: XCTestCase {
    private func client(
        _ transport: any ClientTransport,
        enabled: @escaping @Sendable () -> Bool = { true },
        matching: Bool = true,
        provenance: DeviceTokenProvenance = .exchanged
    ) throws -> APIClient {
        let session = try testCredentialSessionStore(origin: ReviewFixtures.origin, token: "session-token")
        let pairing = ReceiptPairing(
            store: MemoryDeviceTokenStore(ReviewFixtures.device(matching: matching, provenance: provenance)),
            serverURL: { ReviewFixtures.origin }
        )
        pairing.bindSessionStore(session)
        pairing.setServerFeatures(ReviewFixtures.features, capabilities: ReviewFixtures.capabilities(matching: matching))
        return APIClient(transport: transport, receiptPairing: pairing, sessionStore: session,
                         receiptReviewEnabled: enabled)
    }

    func testListAndDetailUseOnlyDeviceBearerAndDeployedFilters() async throws {
        let listTransport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
            "receipts": [ReviewFixtures.summaryObject(hints: true)], "next_cursor": NSNull(),
        ]), as: UTF8.self))
        let api = try client(listTransport)
        let page = try await api.listImportedReceipts(cursor: nil, scope: ReviewFixtures.scope)
        XCTAssertEqual(page.receipts.first?.payeeHost, "hestia.example")
        var sent = try XCTUnwrap(listTransport.last)
        XCTAssertEqual(sent.request.method, .post)
        XCTAssertEqual(sent.request.path, "/api/budget/receipts/list")
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(sent.request.headerFields[.cookie])
        XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.52.0")
        let listBody = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(listBody["status"] as? String, "imported")
        XCTAssertEqual(listBody["evidence"] as? String, "exclude")
        XCTAssertEqual(listBody["limit"] as? Int, 200)

        let detailTransport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
            "receipt": ReviewFixtures.detailObject(), "candidates": [ReviewFixtures.candidateObject()],
        ]), as: UTF8.self))
        let detailAPI = try client(detailTransport)
        let detail = try await detailAPI.receiptDetail(id: ReviewFixtures.ids[0], scope: ReviewFixtures.scope)
        XCTAssertEqual(detail.candidates?.first?.matchStrength, .nip)
        sent = try XCTUnwrap(detailTransport.last)
        XCTAssertEqual(sent.request.method, .get)
        XCTAssertEqual(sent.request.path, "/api/budget/receipts/detail?receipt_id=\(ReviewFixtures.ids[0])")
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(sent.request.headerFields[.cookie])
        XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.52.0")
    }

    func testSingleConfirmWireHasLinkOrExplicitNull() async throws {
        for linked in [true, false] {
            var receiptObject = ReviewFixtures.detailObject()
            receiptObject["status"] = "confirmed"
            let transport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
                "ok": true, "receipt": receiptObject,
            ]), as: UTF8.self))
            let api = try client(transport)
            let detail = ReviewFixtures.detail(version: 4)
            let candidate = ReviewFixtures.candidate()
            var form = ReceiptForm(draft: detail, candidates: [candidate])
            if !linked { form.candidate = nil }
            var request = try XCTUnwrap(form.request(
                receiptID: detail.receiptId, version: detail.version, candidates: [candidate]
            ))
            request.lines = nil
            request.rawShopName = nil

            _ = try await api.confirmImportedReceipt(request, scope: ReviewFixtures.scope)

            let sent = try XCTUnwrap(transport.last)
            XCTAssertEqual(sent.request.path, "/api/budget/receipts/confirm")
            XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
            XCTAssertNil(sent.request.headerFields[.cookie])
            XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.52.0")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
            XCTAssertEqual(object["expected_version"] as? Int, 4)
            XCTAssertNil(object["raw_shop_name"])
            XCTAssertNil(object["raw_nip"])
            XCTAssertNil(object["lines"])
            if linked {
                XCTAssertEqual((object["link"] as? [String: Any])?["entry_reference"] as? String, "entry-0")
            } else {
                XCTAssertTrue(object["link"] is NSNull)
            }
        }
    }

    func testLinkedConfirmWithoutMatchPermissionSendsNothing() async throws {
        let transport = CapturingTransport(status: 200, body: "{}")
        let api = try client(transport, matching: false)
        let detail = ReviewFixtures.detail()
        let candidate = ReviewFixtures.candidate()
        let request = try XCTUnwrap(ReceiptForm(draft: detail, candidates: [candidate]).request(
            receiptID: detail.receiptId, version: 1, candidates: [candidate]
        ))
        do {
            _ = try await api.confirmImportedReceipt(request, scope: ReviewFixtures.scope)
            XCTFail("Expected matching denial")
        } catch is CancellationError {}
        XCTAssertNil(transport.last)
    }

    func testFlagOffAndNonExchangedTokenSendZeroRequests() async throws {
        let detail = ReviewFixtures.detail()
        let form = ReceiptForm(draft: detail, candidates: [])
        let request = try XCTUnwrap(form.request(receiptID: detail.receiptId, version: 1, candidates: []))
        for provenance in [DeviceTokenProvenance.exchanged, .legacyPasswordLogin] {
            let transport = CapturingTransport(status: 200, body: "{}")
            let enabled = provenance == .exchanged ? false : true
            let api = try client(transport, enabled: { enabled }, provenance: provenance)
            for call in [
                { _ = try await api.listImportedReceipts(cursor: nil, scope: ReviewFixtures.scope) },
                { _ = try await api.receiptDetail(id: detail.receiptId, scope: ReviewFixtures.scope) },
                { _ = try await api.confirmImportedReceipt(request, scope: ReviewFixtures.scope) },
            ] {
                do { try await call(); XCTFail("Expected the request to be blocked") } catch {}
            }
            XCTAssertNil(transport.last)
        }
    }
}
