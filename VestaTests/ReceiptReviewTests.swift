import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

private enum ReviewFixtures {
    static let origin = URL(string: "https://hestia.example")!
    static let ownerKey = String(repeating: "b", count: 43)
    static let groupID = "00000000-0000-0000-0000-000000000010"
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
        .init(summary: summary(index, shop: shop, version: version), lines: [.init()])
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

    static func device(matching: Bool = true, provenance: DeviceTokenProvenance = .exchanged,
                       owner: String = "u") -> StoredReceiptDeviceToken {
        var permissions = ReceiptReviewGate.requiredPermissions
        if matching { permissions.insert(.budgetReceiptsMatch) }
        return .init(server: origin, provenance: provenance, actor: "u", owner: owner, ownerKey: ownerKey,
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

    static func groupObject() -> [String: Any] {
        let reference: [String: Any] = [
            "group_id": groupID, "group_status": "confirmed", "group_version": 1, "member_count": 2,
            "fee_amount": NSNull(), "evidence_receipt_id": NSNull(),
        ]
        let members = (0...1).map { index in
            var member = summaryObject(index)
            member["status"] = "confirmed"
            member["linked"] = true
            member["link_group"] = reference
            return member
        }
        return [
            "group": reference, "members": members, "evidence": NSNull(),
            "linked_account_id": NSNull(), "linked_entry_ref": NSNull(),
        ]
    }

    static func groupDetail() throws -> BudgetReceiptGroupDetailResultWire {
        try JSONDecoder().decode(BudgetReceiptGroupDetailResultWire.self, from: data(groupObject()))
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
        case linkedList(String?)
        case detail(String)
        case groupedReceiptDetail(String)
        case groupDetail(String)
        case confirm(String, Int, String?)
    }

    private(set) var calls: [Call] = []
    private(set) var confirms: [ReceiptConfirmRequest] = []
    private var pages: [String: ReceiptListPage] = [:]
    private var linkedPages: [String: ReceiptListPage] = [:]
    private var details: [String: Result<ReceiptDetailResult, ReceiptError>] = [:]
    private var groupResults: [String: Result<BudgetReceiptGroupDetailResultWire, ReceiptError>] = [:]
    private var confirmErrors: [String: ReceiptError] = [:]
    private var detailGates: [String: ReviewResponseGate] = [:]
    private var groupGates: [String: ReviewResponseGate] = [:]
    private var confirmGates: [String: ReviewResponseGate] = [:]
    var listError: ReceiptError?

    func setPage(cursor: String?, receipts: [ImportedReceiptSummary], next: String?) {
        pages[cursor ?? "first"] = .init(receipts: receipts, nextCursor: next)
    }

    func setLinkedPage(cursor: String? = nil, receipts: [ImportedReceiptSummary], next: String? = nil) {
        linkedPages[cursor ?? "first"] = .init(receipts: receipts, nextCursor: next)
    }

    func setDetail(_ receipt: ReceiptDetail, candidates: [ReceiptCandidate]? = nil) {
        details[receipt.summary.receiptId] = .success(.init(receipt: receipt, candidates: candidates))
    }

    func setDetailError(_ id: String, _ error: ReceiptError) { details[id] = .failure(error) }
    func setConfirmError(_ id: String, _ error: ReceiptError?) { confirmErrors[id] = error }
    func holdDetail(_ id: String, gate: ReviewResponseGate) { detailGates[id] = gate }
    func holdConfirm(_ id: String, gate: ReviewResponseGate) { confirmGates[id] = gate }

    func setGroupResult(_ id: String, _ result: Result<BudgetReceiptGroupDetailResultWire, ReceiptError>) {
        groupResults[id] = result
    }

    func holdGroup(_ id: String, gate: ReviewResponseGate) { groupGates[id] = gate }

    func listImportedReceipts(cursor: String?, scope: ReceiptSessionScope) async throws -> ReceiptListPage {
        calls.append(.list(cursor))
        if let listError { throw listError }
        return pages[cursor ?? "first"] ?? .init(receipts: [])
    }

    func listLinkedReceipts(cursor: String?, scope: ReceiptSessionScope) async throws -> ReceiptListPage {
        calls.append(.linkedList(cursor))
        return linkedPages[cursor ?? "first"] ?? .init(receipts: [])
    }

    func receiptDetail(id: String, scope: ReceiptSessionScope, includeGroup: Bool) async throws -> ReceiptDetailResult {
        calls.append(includeGroup ? .groupedReceiptDetail(id) : .detail(id))
        if let gate = detailGates[id] { await gate.wait() }
        if let result = details[id] { return try result.get() }
        let components = id.split(separator: "-")
        let index = components.last.flatMap { Int($0) }.map { max(0, $0 - 1) } ?? 0
        return .init(receipt: ReviewFixtures.detail(index), candidates: nil)
    }

    func receiptGroupDetail(id: String, scope: ReceiptSessionScope) async throws -> BudgetReceiptGroupDetailResultWire {
        calls.append(.groupDetail(id))
        let result = groupResults[id] ?? .failure(.notFound)
        if let gate = groupGates[id] { await gate.wait() }
        return try result.get()
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail {
        calls.append(.confirm(request.receiptId, request.expectedVersion, request.link?.entryReference))
        confirms.append(request)
        if let gate = confirmGates[request.receiptId] { await gate.wait() }
        if let error = confirmErrors[request.receiptId] { throw error }
        let index = ReviewFixtures.ids.firstIndex(of: request.receiptId) ?? 0
        var detail = ReviewFixtures.detail(index, version: request.expectedVersion + 1)
        detail.summary.status = .confirmed
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
        XCTAssertEqual(present.summary.gatewayStatus, .registered)
        XCTAssertEqual(present.summary.payeeHost, "hestia.example")
        XCTAssertEqual(present.summary.hasDocument, false)
        let encoded = try JSONEncoder().encode(present)
        XCTAssertEqual(try JSONDecoder().decode(ReceiptDetail.self, from: encoded), present)
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
        XCTAssertNil(result.draft.summary.linkedEntryRef)
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
        XCTAssertEqual(calls, [.list(nil), .list("next"), .linkedList(nil)])
    }

    func testLinkedPagesSurfaceOnlyGroupedReceiptsAndKeepThemReadOnly() async throws {
        let api = MockReceiptReviewAPI()
        let group = try ReviewFixtures.groupDetail()
        let grouped = group.members
        var needsReview = grouped[1]
        needsReview.status = .needsReview
        var ordinary = ReviewFixtures.summary(2)
        ordinary.status = .confirmed
        ordinary.linked = true
        await api.setPage(cursor: nil, receipts: [ReviewFixtures.summary(3)], next: nil)
        await api.setLinkedPage(receipts: [grouped[0], ordinary], next: "linked-next")
        await api.setLinkedPage(cursor: "linked-next", receipts: [grouped[0], needsReview])
        await api.setDetail(.init(summary: grouped[0], lines: []), candidates: [ReviewFixtures.candidate()])
        await api.setGroupResult(group.group.groupId, .success(group))
        let store = ReceiptReviewStore(api: api, scope: scope)

        await store.load()
        XCTAssertEqual(store.receipts.map(\.receiptId), [ReviewFixtures.ids[3], grouped[0].receiptId, needsReview.receiptId])
        await store.select(grouped[0])

        XCTAssertEqual(store.detail?.summary.linkGroup?.groupId, ReviewFixtures.groupID)
        XCTAssertFalse(store.canConfirmSelected)
        XCTAssertTrue(store.candidates.isEmpty)
        await store.confirmSelected()
        await store.loadGroup(id: group.group.groupId)
        XCTAssertEqual(store.groupDetail, group)
        store.dismissGroup()
        XCTAssertNil(store.groupDetail)
        XCTAssertEqual(store.detail?.summary.receiptId, grouped[0].receiptId)
        let calls = await api.calls
        XCTAssertEqual(calls, [
            .list(nil), .linkedList(nil), .linkedList("linked-next"), .groupedReceiptDetail(grouped[0].receiptId),
            .groupDetail(group.group.groupId),
        ])
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
        XCTAssertNil(store.totalAdjustment)
        await store.confirmSelected()

        let confirms = await api.confirms
        let request = try XCTUnwrap(confirms.first)
        XCTAssertEqual(request.expectedVersion, 7)
        XCTAssertEqual(request.link?.entryReference, "entry-0")
        XCTAssertEqual(request.link?.candidateToken, "candidate-0")
        XCTAssertNil(request.lines)
        XCTAssertTrue(store.receipts.isEmpty)
        XCTAssertEqual(store.outcomes.first?.status, .confirmed)
    }

    func testRemainderNoteKeepsPreselectedLinkAndConfirmsInOneTap() async throws {
        let api = MockReceiptReviewAPI()
        var detail = ReviewFixtures.detail(version: 4)
        detail.lines = [.init(grossLineTotal: "7.34", netLineTotal: "7.34", unitPriceRaw: "7.34")]
        let candidate = ReviewFixtures.candidate()
        await api.setPage(cursor: nil, receipts: [detail.summary], next: nil)
        await api.setDetail(detail, candidates: [candidate])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(detail.summary)

        XCTAssertEqual(store.totalAdjustment, .remainder(amount: "5"))
        XCTAssertEqual(store.selectedCandidate, ReceiptForm.CandidateID(candidate))
        XCTAssertTrue(store.canConfirmSelected)
        await store.confirmSelected()

        let confirms = await api.confirms
        XCTAssertEqual(confirms.count, 1)
        let request = try XCTUnwrap(confirms.first)
        XCTAssertEqual(request.link?.accountId, candidate.accountId)
        XCTAssertEqual(request.link?.entryReference, candidate.entryReference)
        XCTAssertEqual(request.link?.candidateToken, candidate.candidateToken)
        XCTAssertEqual(request.lines?.map(\.rawName), ["Item", "Pozostałe / nierozpoznane pozycje"])
        XCTAssertEqual(request.lines?.map(\.netLineTotal), ["7.34", "5"])
        XCTAssertEqual(store.confirmedReceiptID, detail.summary.receiptId)
        XCTAssertNil(store.totalAdjustment)
    }

    func testRedactedLineShowsSummaryNoteAndIsNeverSent() async throws {
        let api = MockReceiptReviewAPI()
        var detail = ReviewFixtures.detail()
        detail.lines = [.init(grossLineTotal: "7.34", netLineTotal: "7.34", rawName: "[usunięto]")]
        await api.setPage(cursor: nil, receipts: [detail.summary], next: nil)
        await api.setDetail(detail)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(detail.summary)

        XCTAssertEqual(store.totalAdjustment, .summary)
        XCTAssertTrue(store.canConfirmSelected)
        await store.confirmSelected()

        let confirms = await api.confirms
        let lines = try XCTUnwrap(confirms.first?.lines)
        XCTAssertEqual(lines.map(\.rawName), ["Tylko suma"])
        XCTAssertEqual(lines.map(\.netLineTotal), ["12.34"])
    }

    func testPaymentConfirmationDisablesSaveAndShowsMismatchBeforeTap() async {
        let api = MockReceiptReviewAPI()
        var detail = ReviewFixtures.detail()
        detail.summary.documentKind = .paymentConfirmation
        detail.lines = [.init(grossLineTotal: "7.34", netLineTotal: "7.34")]
        await api.setPage(cursor: nil, receipts: [detail.summary], next: nil)
        await api.setDetail(detail)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(detail.summary)

        XCTAssertNil(store.totalAdjustment)
        XCTAssertFalse(store.canConfirmSelected)
        XCTAssertEqual(store.confirmLineError, .totalMismatch)
        await store.confirmSelected()

        let confirms = await api.confirms
        XCTAssertTrue(confirms.isEmpty)
    }

    func testMissingOrInvalidTotalDisablesSaveAndShowsReasonBeforeTap() async {
        let invalidTotals: [String?] = [nil, "", "invalid", "0.00", "-12.34"]
        for total in invalidTotals {
            let api = MockReceiptReviewAPI()
            var detail = ReviewFixtures.detail()
            detail.summary.totalAmount = total
            await api.setPage(cursor: nil, receipts: [detail.summary], next: nil)
            await api.setDetail(detail)
            let store = ReceiptReviewStore(api: api, scope: scope)
            await store.load()
            await store.select(detail.summary)

            XCTAssertNil(store.totalAdjustment)
            XCTAssertFalse(store.canConfirmSelected)
            XCTAssertEqual(store.confirmLineError, .invalidTotal)
            XCTAssertEqual(store.confirmLineError?.message.key, "The receipt total is missing or invalid.")
            await store.confirmSelected()

            let confirms = await api.confirms
            XCTAssertTrue(confirms.isEmpty)
        }
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
            var detail = ReviewFixtures.detail(index, version: 11 + index)
            if index == 0 { detail.summary.totalAmount = "10" }
            await api.setDetail(detail, candidates: [ReviewFixtures.candidate(index)])
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
            .list(nil), .linkedList(nil), .detail(ReviewFixtures.ids[0]), .confirm(ReviewFixtures.ids[0], 11, nil),
        ])
        await firstGate.release()
        await bulk.value

        calls = await api.calls
        XCTAssertEqual(calls, [
            .list(nil), .linkedList(nil),
            .detail(ReviewFixtures.ids[0]), .confirm(ReviewFixtures.ids[0], 11, nil),
            .detail(ReviewFixtures.ids[1]), .confirm(ReviewFixtures.ids[1], 12, nil),
            .detail(ReviewFixtures.ids[2]), .confirm(ReviewFixtures.ids[2], 13, nil),
        ])
        XCTAssertEqual(store.outcomes.map(\.status), [.confirmed, .failed, .alreadySubmitted])
        XCTAssertEqual(store.outcomes.map(\.code), ["confirmed", "budget_receipt_conflict", "already_submitted"])
        XCTAssertEqual(store.receipts.map(\.receiptId), [ReviewFixtures.ids[1]])
        let confirms = await api.confirms
        XCTAssertTrue(confirms.allSatisfy { $0.link == nil })
        XCTAssertEqual(confirms.first?.lines?.map(\.rawName), ["Tylko suma"])
        XCTAssertEqual(confirms.first?.lines?.map(\.netLineTotal), ["10"])
        XCTAssertEqual(store.outcomes.first?.adjustment, .summary)
    }

    func testBulkSkipsReceiptsConfirmedLinkedOrChangedSinceListing() async throws {
        let api = MockReceiptReviewAPI()
        let receipts = (0...3).map { ReviewFixtures.summary($0, version: 3) }
        await api.setPage(cursor: nil, receipts: receipts, next: nil)
        var confirmed = ReviewFixtures.detail(0, version: 9)
        confirmed.summary.status = .confirmed
        confirmed.summary.linked = true
        await api.setDetail(confirmed)
        var linked = ReviewFixtures.detail(1, version: 5)
        linked.summary.linked = true
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

    func testInvoiceWithNoLinesSendsInvoiceNumberLineAndHidesNote() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        var invoice = ReviewFixtures.detail()
        invoice.summary.documentKind = .invoice
        invoice.summary.invoiceNumber = " INV-001 "
        invoice.lines = []
        invoice.summary.receiptTime = ""
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(invoice)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)
        XCTAssertNil(store.totalAdjustment)
        XCTAssertTrue(store.canConfirmSelected)
        await store.confirmSelected()

        let confirms = await api.confirms
        let request = try XCTUnwrap(confirms.first)
        XCTAssertNil(request.receiptTime)
        XCTAssertEqual(request.lines?.count, 1)
        let line = try XCTUnwrap(request.lines?.first)
        XCTAssertEqual(line.rawName, "INV-001")
        XCTAssertEqual(line.lineKind, .other)
        XCTAssertEqual(line.grossLineTotal, request.totalAmount)
        XCTAssertEqual(line.netLineTotal, request.totalAmount)
        XCTAssertEqual(line.discountAmount, "0")
        XCTAssertEqual(line.quantity, "1")
        XCTAssertNil(store.outcomes.first?.adjustment)
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
            ReviewFixtures.device(provenance: .legacyPasswordLogin), origin: ReviewFixtures.origin, actor: "u",
            capabilities: ReviewFixtures.capabilities()
        ))

        let noMatch = try ReviewAppFixture(matching: false)
        await noMatch.connect()
        let store = try XCTUnwrap(noMatch.app.makeReceiptReviewStore())
        XCTAssertNotNil(noMatch.app.receiptReviewAPI)
        XCTAssertFalse(store.canMatchReceipts)
    }

    func testCurrentGrantsMustBelongToTheTokenLedger() {
        let ownToken = ReviewFixtures.device()
        let delegatedToken = ReviewFixtures.device(owner: "other")
        let reviewGrants: Set<Permission> = [.budgetReceiptsAdd, .budgetReceiptsView, .budgetReceiptsEdit]
        let delegatedGrants: Set<Permission> = [.budgetReceiptsAdd, .budgetReceiptsView, .budgetReceiptsMatch]
        let capabilities = Capabilities(
            user: "u",
            ownBudget: .init(permissions: reviewGrants, canView: true, canUseReceipts: true, canManageDevices: true),
            delegatedReceipts: .init(permissions: delegatedGrants, canUse: true)
        )
        XCTAssertTrue(ReceiptReviewGate.allowsDevice(
            ownToken, origin: ReviewFixtures.origin, actor: "u", capabilities: capabilities
        ))
        XCTAssertFalse(ReceiptReviewGate.allowsMatching(ownToken, capabilities: capabilities))
        XCTAssertFalse(ReceiptReviewGate.allowsDevice(
            delegatedToken, origin: ReviewFixtures.origin, actor: "u", capabilities: capabilities
        ))

        let delegatedOnly = Capabilities(user: "u", delegatedReceipts: .init(permissions: reviewGrants, canUse: true))
        XCTAssertTrue(ReceiptReviewGate.allowsDevice(
            delegatedToken, origin: ReviewFixtures.origin, actor: "u", capabilities: delegatedOnly
        ))
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

    func testGroup401And403TearDownReceiptReview() async throws {
        let result = try ReviewFixtures.groupDetail()
        for error in [ReceiptError.api(.unauthorized), .forbidden] {
            let fixture = try ReviewAppFixture()
            await fixture.connect()
            let receipt = ReviewFixtures.summary(2)
            await fixture.review.setPage(cursor: nil, receipts: [receipt], next: nil)
            await fixture.review.setLinkedPage(receipts: result.members)
            await fixture.review.setDetail(ReviewFixtures.detail(2), candidates: [ReviewFixtures.candidate()])
            await fixture.review.setGroupResult(ReviewFixtures.groupID, .failure(error))
            let store = try XCTUnwrap(fixture.app.makeReceiptReviewStore())
            await store.load()
            await store.select(receipt)
            XCTAssertNotNil(store.detail)
            XCTAssertFalse(store.candidates.isEmpty)

            await store.loadGroup(id: ReviewFixtures.groupID)

            XCTAssertTrue(store.isCleared)
            XCTAssertTrue(store.receipts.isEmpty)
            XCTAssertTrue(store.candidates.isEmpty)
            XCTAssertNil(store.detail)
            XCTAssertNil(store.groupID)
            XCTAssertNil(store.groupDetail)
            XCTAssertNil(store.groupFailure)
            let calls = await fixture.review.calls
            XCTAssertEqual(calls.last, .groupDetail(ReviewFixtures.groupID))
            await store.loadGroup(id: ReviewFixtures.groupID)
            let callsAfterRetry = await fixture.review.calls
            XCTAssertEqual(callsAfterRetry, calls)
        }
    }

    func testSessionSwitchDropsLateGroupResponses() async throws {
        let result = try ReviewFixtures.groupDetail()
        for scenario in ["sign out", "account", "origin"] {
            let fixture = try ReviewAppFixture()
            await fixture.connect()
            await fixture.review.setLinkedPage(receipts: result.members)
            await fixture.review.setGroupResult(ReviewFixtures.groupID, .success(result))
            let gate = ReviewResponseGate()
            await fixture.review.holdGroup(ReviewFixtures.groupID, gate: gate)
            let store = try XCTUnwrap(fixture.app.makeReceiptReviewStore())
            await store.load()
            let loading = Task { await store.loadGroup(id: ReviewFixtures.groupID) }
            try await waitUntil("held group response before \(scenario)") { await gate.isWaiting }
            XCTAssertEqual(store.groupID, ReviewFixtures.groupID)

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
            await loading.value

            XCTAssertNil(store.groupID, scenario)
            XCTAssertNil(store.groupDetail, scenario)
            XCTAssertNil(store.groupFailure, scenario)
            XCTAssertTrue(store.receipts.isEmpty, scenario)
        }
    }

    func testDismissedGroupDropsLateDenialWithoutClosingReview() async throws {
        let fixture = try ReviewAppFixture()
        await fixture.connect()
        await fixture.review.setLinkedPage(receipts: try ReviewFixtures.groupDetail().members)
        await fixture.review.setGroupResult(ReviewFixtures.groupID, .failure(.forbidden))
        let gate = ReviewResponseGate()
        await fixture.review.holdGroup(ReviewFixtures.groupID, gate: gate)
        let store = try XCTUnwrap(fixture.app.makeReceiptReviewStore())
        await store.load()
        let receipts = store.receipts

        let loading = Task { await store.loadGroup(id: ReviewFixtures.groupID) }
        try await waitUntil("held denial for dismissed group sheet") { await gate.isWaiting }
        store.dismissGroup()
        await gate.release()
        await loading.value

        XCTAssertFalse(store.isCleared)
        XCTAssertEqual(store.receipts, receipts)
        XCTAssertNil(store.groupID)
        XCTAssertNil(store.groupDetail)
        XCTAssertNil(store.groupFailure)
    }
}

private actor ReviewGroupTransport: ClientTransport {
    struct Call: Sendable {
        let request: HTTPRequest
        let hasBody: Bool
    }

    private let status: Int
    private let responseBody: Data?
    private(set) var calls: [Call] = []

    init(status: Int = 200, responseBody: Data? = nil) {
        self.status = status
        self.responseBody = responseBody
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        calls.append(.init(request: request, hasBody: body != nil))
        var response = HTTPResponse(status: .init(code: status))
        guard let responseBody else { return (response, nil) }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody([UInt8](responseBody)))
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

    func testGroupDetailUsesDeviceBearerAndSendsOnlyABodylessGET() async throws {
        let transport = ReviewGroupTransport(responseBody: try ReviewFixtures.data(ReviewFixtures.groupObject()))
        let api = try client(transport, matching: false)

        let result = try await api.receiptGroupDetail(id: ReviewFixtures.groupID, scope: ReviewFixtures.scope)

        XCTAssertEqual(result.group.groupId, ReviewFixtures.groupID)
        XCTAssertEqual(result.members.map(\.receiptId), Array(ReviewFixtures.ids.prefix(2)))
        XCTAssertNil(result.evidence)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.request.path), ["/api/budget/receipts/group/detail?group_id=\(ReviewFixtures.groupID)"])
        let sent = try XCTUnwrap(calls.first)
        XCTAssertEqual(sent.request.method, .get)
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(sent.request.headerFields[.cookie])
        XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.59.0")
        XCTAssertFalse(sent.hasBody)
    }

    func testLinkedListAndGroupedReceiptDetailRequestGroupContract() async throws {
        let group = ReviewFixtures.groupObject()
        let members = try XCTUnwrap(group["members"] as? [[String: Any]])
        let listTransport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
            "receipts": members, "next_cursor": NSNull(),
        ]), as: UTF8.self))
        let api = try client(listTransport)

        let page = try await api.listLinkedReceipts(cursor: "next", scope: ReviewFixtures.scope)

        XCTAssertEqual(page.receipts.map { $0.linkGroup?.groupId }, [ReviewFixtures.groupID, ReviewFixtures.groupID])
        let list = try XCTUnwrap(listTransport.last)
        XCTAssertEqual(list.request.method, .post)
        XCTAssertEqual(list.request.path, "/api/budget/receipts/list")
        XCTAssertEqual(list.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.59.0")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: list.body) as? [String: Any])
        XCTAssertEqual(body["linked"] as? Bool, true)
        XCTAssertEqual(body["cursor"] as? String, "next")
        XCTAssertEqual(body["evidence"] as? String, "exclude")
        XCTAssertNil(body["status"])

        var receipt = try XCTUnwrap(members.first)
        receipt["lines"] = [] as [[String: Any]]
        let detailTransport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
            "receipt": receipt,
        ]), as: UTF8.self))
        let detailAPI = try client(detailTransport)

        let detail = try await detailAPI.receiptDetail(id: ReviewFixtures.ids[0], scope: ReviewFixtures.scope, includeGroup: true)

        XCTAssertEqual(detail.receipt.summary.linkGroup?.groupId, ReviewFixtures.groupID)
        let detailCall = try XCTUnwrap(detailTransport.last)
        XCTAssertEqual(detailCall.request.method, .get)
        XCTAssertEqual(detailCall.request.path, "/api/budget/receipts/detail?receipt_id=\(ReviewFixtures.ids[0])")
        XCTAssertEqual(detailCall.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.59.0")
    }

    func testLinkedListTreatsOnlyUnsupportedContractAsEmpty() async throws {
        let unsupported = try client(CapturingTransport(status: 400, body: #"{"ok":false,"error":"budget_receipt_contract_version_invalid"}"#))
        let page = try await unsupported.listLinkedReceipts(cursor: nil, scope: ReviewFixtures.scope)
        XCTAssertTrue(page.receipts.isEmpty)
        XCTAssertNil(page.nextCursor)

        let invalid = try client(CapturingTransport(status: 400, body: #"{"ok":false,"error":"invalid_request"}"#))
        do {
            _ = try await invalid.listLinkedReceipts(cursor: nil, scope: ReviewFixtures.scope)
            XCTFail("Expected the unrelated error to propagate")
        } catch {
            XCTAssertEqual(error as? ReceiptError, .rejected("invalid_request"))
        }
    }

    func testGroupDenialsNeverRetryWithCookie() async throws {
        for (status, expected) in [(401, ReceiptError.api(.unauthorized)), (403, .forbidden)] {
            let transport = ReviewGroupTransport(status: status)
            let api = try client(transport)

            do {
                _ = try await api.receiptGroupDetail(id: ReviewFixtures.groupID, scope: ReviewFixtures.scope)
                XCTFail("Expected HTTP \(status) to deny group detail")
            } catch {
                XCTAssertEqual(error as? ReceiptError, expected)
            }

            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
            XCTAssertNil(calls.first?.request.headerFields[.cookie])
        }
    }

    func testGroupFlagOffSendsZeroRequests() async throws {
        let transport = ReviewGroupTransport()
        let api = try client(transport, enabled: { false })

        do {
            _ = try await api.receiptGroupDetail(id: ReviewFixtures.groupID, scope: ReviewFixtures.scope)
            XCTFail("Expected the disabled group request to be blocked")
        } catch {
            XCTAssertEqual(error as? ReceiptError, .forbidden)
        }

        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSingleConfirmWireHasAdjustmentWithLinkOrOmitsLinesWithExplicitUnlink() async throws {
        for linked in [true, false] {
            var receiptObject = ReviewFixtures.detailObject()
            receiptObject["status"] = "confirmed"
            let transport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
                "ok": true, "receipt": receiptObject,
            ]), as: UTF8.self))
            let api = try client(transport)
            var detail = ReviewFixtures.detail(version: 4)
            if linked { detail.summary.totalAmount = "15" }
            let candidate = ReviewFixtures.candidate()
            var form = ReceiptForm(draft: detail, candidates: [candidate])
            if !linked { form.candidate = nil }
            var request = try XCTUnwrap(form.request(
                receiptID: detail.summary.receiptId, version: detail.summary.version, candidates: [candidate]
            ))
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
            if linked {
                let lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
                XCTAssertEqual(lines.count, 2)
                let remainder = try XCTUnwrap(lines.last)
                XCTAssertEqual(remainder["raw_name"] as? String, "Pozostałe / nierozpoznane pozycje")
                XCTAssertEqual(remainder["net_line_total"] as? String, "2.66")
                XCTAssertTrue(remainder["raw_unit"] is NSNull)
                XCTAssertEqual((object["link"] as? [String: Any])?["entry_reference"] as? String, "entry-0")
            } else {
                XCTAssertNil(object["lines"])
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
            receiptID: detail.summary.receiptId, version: 1, candidates: [candidate]
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
        let request = try XCTUnwrap(form.request(receiptID: detail.summary.receiptId, version: 1, candidates: []))
        for provenance in [DeviceTokenProvenance.exchanged, .legacyPasswordLogin] {
            let transport = CapturingTransport(status: 200, body: "{}")
            let enabled = provenance == .exchanged ? false : true
            let api = try client(transport, enabled: { enabled }, provenance: provenance)
            for call in [
                { _ = try await api.listImportedReceipts(cursor: nil, scope: ReviewFixtures.scope) },
                { _ = try await api.receiptDetail(id: detail.summary.receiptId, scope: ReviewFixtures.scope) },
                { _ = try await api.confirmImportedReceipt(request, scope: ReviewFixtures.scope) },
            ] {
                do { try await call(); XCTFail("Expected the request to be blocked") } catch {}
            }
            XCTAssertNil(transport.last)
        }
    }
}
