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
    static let linkedTransaction = BudgetReceiptLinkedTransactionWire(
        accountLabel: "Test account", bookingDate: "2026-11-23", amount: "-12.34", currency: "PLN"
    )

    static func summary(_ index: Int = 0, shop: String? = "Shop", chain: String? = nil, version: Int = 1) -> ReceiptReviewSummary {
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
    private var pages: [String: ReceiptReviewPage] = [:]
    private var details: [String: Result<ReceiptDetailResult, ReceiptError>] = [:]
    private var confirmErrors: [String: ReceiptError] = [:]
    private var detailGates: [String: ReviewResponseGate] = [:]
    private var confirmGates: [String: ReviewResponseGate] = [:]
    var listError: ReceiptError?

    func setPage(cursor: String?, receipts: [ReceiptReviewSummary], next: String?) {
        pages[cursor ?? "first"] = .init(
            receipts: receipts, nextCursor: next.map { ReceiptReviewCursor(value: $0, filter: .needsAction) }
        )
    }

    func setDetail(_ receipt: ReceiptDetail, candidates: [ReceiptCandidate]? = nil) {
        details[receipt.summary.receiptId] = .success(.init(receipt: receipt, candidates: candidates))
    }

    func setDetailError(_ id: String, _ error: ReceiptError) { details[id] = .failure(error) }
    func setConfirmError(_ id: String, _ error: ReceiptError?) { confirmErrors[id] = error }
    func holdDetail(_ id: String, gate: ReviewResponseGate) { detailGates[id] = gate }
    func holdConfirm(_ id: String, gate: ReviewResponseGate) { confirmGates[id] = gate }

    func listReviewReceipts(cursor: ReceiptReviewCursor?, scope: ReceiptSessionScope) async throws -> ReceiptReviewPage {
        calls.append(.list(cursor?.value))
        if let listError { throw listError }
        return pages[cursor?.value ?? "first"] ?? .init(receipts: [])
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
        detail.summary.status = .confirmed
        return detail
    }
}

final class ReceiptReviewMappingTests: XCTestCase {
    func testDisplayShopNameInListAndDetailWhenPresentNullOrAbsent() throws {
        for name in ["Issuer", NSNull(), nil] as [Any?] {
            var summaryObject = ReviewFixtures.summaryObject()
            var detailObject = ReviewFixtures.detailObject()
            summaryObject["display_shop_name"] = name
            detailObject["display_shop_name"] = name

            let summary = try JSONDecoder().decode(ReceiptReviewSummary.self, from: ReviewFixtures.data(summaryObject))
            let detail = try JSONDecoder().decode(ReceiptDetail.self, from: ReviewFixtures.data(detailObject))
            XCTAssertEqual(summary.displayShopName, name as? String)
            XCTAssertEqual(detail.summary.displayShopName, name as? String)
            XCTAssertEqual(summary.shopNameForDisplay, (name as? String) ?? "Shop")
            XCTAssertEqual(detail.summary.shopNameForDisplay, summary.shopNameForDisplay)
            XCTAssertEqual(detail.summary.rawShopName, "Shop")
        }
    }

    func testOptionalHintsMayBeAbsentOrPresent() throws {
        let absent = try JSONDecoder().decode(
            ReceiptReviewSummary.self, from: ReviewFixtures.data(ReviewFixtures.summaryObject())
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
            ReceiptReviewSummary.self, from: ReviewFixtures.data(summary)
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
        for strength in [ReceiptCandidate.MatchStrengthPayload.id, .nip, .distinctive] {
            let candidate = ReviewFixtures.candidate(strength: strength)
            XCTAssertEqual(ReceiptReviewStore.preselectedCandidate(from: [candidate]), candidate)
        }
        for strength in [ReceiptCandidate.MatchStrengthPayload.generic, .none, .unknown] {
            XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: [ReviewFixtures.candidate(strength: strength)]))
        }
        XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: []))
        XCTAssertNil(ReceiptReviewStore.preselectedCandidate(from: [
            ReviewFixtures.candidate(0, strength: .id), ReviewFixtures.candidate(1, strength: .distinctive),
        ]))
    }
}

@MainActor
final class ReceiptReviewStoreTests: XCTestCase {
    private let scope = ReviewFixtures.scope

    func testLinkIndicatorShowsBankDateAndAmountWhenAvailable() {
        XCTAssertEqual(
            ReceiptLinkIndicator(transaction: ReviewFixtures.linkedTransaction).text,
            "🏦 2026-11-23 · -12.34 PLN"
        )
        let transaction = BudgetReceiptLinkedTransactionWire(
            accountLabel: "Test account", bookingDate: nil, amount: nil, currency: nil
        )
        XCTAssertEqual(ReceiptLinkIndicator(transaction: transaction).text, "🏦")
        XCTAssertNil(ReceiptLinkIndicator(transaction: nil).text)
    }

    func testLinkedReceiptCarriesListTransactionIntoReadOnlyDetail() async throws {
        let api = MockReceiptReviewAPI()
        var detail = ReviewFixtures.detail()
        detail.summary.linked = true
        var summary = detail.summary
        summary.linkedTransaction = ReviewFixtures.linkedTransaction
        let candidate = ReviewFixtures.candidate(strength: .id)
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(detail, candidates: [candidate])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        XCTAssertEqual(store.detail?.summary.linkedTransaction, summary.linkedTransaction)
        XCTAssertEqual(store.receipts, [summary])
        XCTAssertFalse(store.canEditSelectedReceipt)
        XCTAssertFalse(store.canConfirmSelected)
        XCTAssertTrue(store.candidates.isEmpty)
        store.selectCandidate(candidate)
        store.selectCandidate(nil)
        XCTAssertNil(store.selectedCandidate)
        XCTAssertFalse(store.hasLinkChoice)
        await store.confirmSelected()
        let group = try XCTUnwrap(store.groups.first)
        XCTAssertFalse(group.canConfirmWithoutLinking)
        await store.confirmMerchant(group)
        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .detail(summary.receiptId)])
    }

    func testUpdatedLinkedDetailUsesOnlyCurrentTransactionData() async {
        let api = MockReceiptReviewAPI()
        var detail = ReviewFixtures.detail(version: 2)
        detail.summary.linked = true
        var summary = ReviewFixtures.summary()
        summary.linked = true
        summary.linkedTransaction = ReviewFixtures.linkedTransaction
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(detail)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        XCTAssertEqual(store.detail?.summary.version, 2)
        XCTAssertNil(store.detail?.summary.linkedTransaction)
        XCTAssertFalse(store.canConfirmSelected)

        let currentTransaction = BudgetReceiptLinkedTransactionWire(
            accountLabel: "Other test account", bookingDate: "2026-11-24", amount: "-20.00", currency: "EUR"
        )
        detail.summary.linkedTransaction = currentTransaction
        await api.setDetail(detail)
        await store.select(summary)

        XCTAssertEqual(store.detail?.summary.linkedTransaction, currentTransaction)
        XCTAssertFalse(store.canConfirmSelected)
    }

    func testStaleUnlinkedRowCannotConfirmAfterReceiptWasLinked() async throws {
        let api = MockReceiptReviewAPI()
        let staleSummary = ReviewFixtures.summary()
        await api.setPage(cursor: nil, receipts: [staleSummary], next: nil)
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        let staleGroup = try XCTUnwrap(store.groups.first)

        var linkedDetail = ReviewFixtures.detail(version: 2)
        linkedDetail.summary.linked = true
        await api.setDetail(linkedDetail, candidates: [ReviewFixtures.candidate(strength: .id)])
        await store.select(staleSummary)
        XCTAssertEqual(store.failure, .versionConflict)
        XCTAssertNil(store.selectedCandidate)
        XCTAssertFalse(store.canConfirmSelected)
        await store.confirmSelected()

        await api.setPage(cursor: nil, receipts: [linkedDetail.summary], next: nil)
        await store.load()
        await store.confirmMerchant(staleGroup)
        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .detail(staleSummary.receiptId), .list(nil)])
    }

    func testUnknownMetadataRequiresManualLinkChoice() async throws {
        enum MetadataLocation: CaseIterable { case list, detail, evidence }
        for location in MetadataLocation.allCases {
            let api = MockReceiptReviewAPI()
            var summary = ReviewFixtures.summary()
            var detail = ReviewFixtures.detail()
            switch location {
            case .list:
                summary.sourceKind = .unknown
            case .detail:
                detail.summary.sourceKind = .unknown
            case .evidence:
                let payment = try JSONDecoder().decode(ReceiptPaymentEvidenceWire.self, from: ReviewFixtures.data([
                    "receipt_id": ReviewFixtures.ids[1], "receipt_date": NSNull(), "total_amount": NSNull(),
                    "fee_amount": NSNull(), "gateway": NSNull(), "gateway_status": "future-status",
                ]))
                detail.paymentEvidence = [payment]
            }
            let candidate = ReviewFixtures.candidate(strength: .id)
            await api.setPage(cursor: nil, receipts: [summary], next: nil)
            await api.setDetail(detail, candidates: [candidate])
            let store = ReceiptReviewStore(api: api, scope: scope)
            await store.load()
            await store.select(summary)

            XCTAssertEqual(store.candidates, [candidate])
            XCTAssertNil(store.selectedCandidate)
            XCTAssertFalse(store.canConfirmSelected)
            store.selectCandidate(candidate)
            XCTAssertTrue(store.canConfirmSelected)
        }
    }

    func testUnknownReceiptStatusBlocksPreselectionAndConfirmation() async throws {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        var detail = ReviewFixtures.detail()
        detail.summary.status = .unknown
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(detail, candidates: [ReviewFixtures.candidate(strength: .id)])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        XCTAssertEqual(store.detail?.summary.status, .unknown)
        XCTAssertNil(store.failure)
        XCTAssertNil(store.selectedCandidate)
        XCTAssertFalse(store.canConfirmSelected)
        await store.confirmSelected()
        await store.confirmMerchant(try XCTUnwrap(store.groups.first))
        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .detail(summary.receiptId), .detail(summary.receiptId)])
    }

    func testCandidateWithUnknownDirectionIsUnsignedAndRequiresManualLinkChoice() async {
        let api = MockReceiptReviewAPI()
        let summary = ReviewFixtures.summary()
        var candidate = ReviewFixtures.candidate(strength: .id)
        candidate.amount = "-12.34"
        candidate.creditDebitIndicator = .unknown
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail(), candidates: [candidate])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()
        await store.select(summary)

        XCTAssertEqual(store.candidates.first?.displayAmount, "12.34")
        XCTAssertNil(store.selectedCandidate)
        XCTAssertFalse(store.canConfirmSelected)
        store.selectCandidate(candidate)
        XCTAssertTrue(store.canConfirmSelected)
    }

    func testUnknownReceiptKindExplainsDisabledSaveAndPreventsConfirmation() async throws {
        for unknownIsOnList in [true, false] {
            let api = MockReceiptReviewAPI()
            var summary = ReviewFixtures.summary()
            var detail = ReviewFixtures.detail()
            if unknownIsOnList {
                summary.receiptKind = .unknown
            } else {
                detail.summary.receiptKind = .unknown
            }
            let candidate = ReviewFixtures.candidate(strength: .id)
            await api.setPage(cursor: nil, receipts: [summary], next: nil)
            await api.setDetail(detail, candidates: [candidate])
            let store = ReceiptReviewStore(api: api, scope: scope)
            await store.load()
            await store.select(summary)

            XCTAssertTrue(store.canEditSelectedReceipt)
            XCTAssertTrue(store.hasUnknownSelectedReceiptKind)
            XCTAssertNil(store.selectedCandidate)
            XCTAssertEqual(store.confirmLineError, .rejected("incomplete_receipt"))
            XCTAssertFalse(store.canConfirmSelected)
            store.selectCandidate(candidate)
            XCTAssertFalse(store.canConfirmSelected)
            await store.confirmSelected()
            await store.confirmMerchant(try XCTUnwrap(store.groups.first))
            let confirms = await api.confirms
            XCTAssertTrue(confirms.isEmpty)
        }
    }

    func testListPaginatesDeduplicatesAndGroupsByMerchant() async {
        let api = MockReceiptReviewAPI()
        await api.setPage(cursor: nil, receipts: [
            ReviewFixtures.summary(0, shop: "Biedronka"),
            ReviewFixtures.summary(1, shop: "Variant", chain: "chain"),
        ], next: "next")
        await api.setPage(cursor: "next", receipts: [
            ReviewFixtures.summary(2, shop: "biedronka"),
            ReviewFixtures.summary(0, shop: "Duplicate"),
        ], next: "third")
        await api.setPage(cursor: "third", receipts: [
            ReviewFixtures.summary(3, shop: "Other", chain: "chain"),
        ], next: nil)
        let store = ReceiptReviewStore(api: api, scope: scope)

        await store.load()

        XCTAssertEqual(store.receipts.map(\.receiptId), [
            ReviewFixtures.ids[0], ReviewFixtures.ids[1], ReviewFixtures.ids[2], ReviewFixtures.ids[3],
        ])
        XCTAssertEqual(store.groups.map(\.name), ["Biedronka", "Variant"])
        XCTAssertEqual(store.groups.map { $0.receipts.count }, [2, 2])
        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .list("next"), .list("third")])
    }

    func testMixedStatusesHaveBadgesAndOnlyUnlinkedImportsCanConfirm() async throws {
        let api = MockReceiptReviewAPI()
        let statuses = ["imported", "needs_review", "draft", "future-status"]
        let receipts = try statuses.enumerated().map { index, status in
            var object = ReviewFixtures.summaryObject(index)
            object["status"] = status
            if status == "draft" { object["source_kind"] = "local_ocr" }
            return try JSONDecoder().decode(ReceiptReviewSummary.self, from: ReviewFixtures.data(object))
        }
        await api.setPage(cursor: nil, receipts: receipts, next: nil)
        for receipt in receipts {
            await api.setDetail(.init(summary: receipt, lines: [.init()]), candidates: [ReviewFixtures.candidate()])
        }
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()

        XCTAssertEqual(store.receipts, receipts)
        XCTAssertEqual(store.receipts.map { $0.status.reviewBadge.key }, ["Imported", "Needs review", "Draft", "Unknown"])
        XCTAssertEqual(store.receipts.map { $0.status.requiresWebReview }, [false, true, true, false])
        XCTAssertFalse(ReceiptMerchantGroup.group(Array(receipts.dropFirst()))[0].canConfirmWithoutLinking)
        for receipt in store.receipts {
            await store.select(receipt)
            XCTAssertEqual(store.detail?.summary, receipt)
            XCTAssertNil(store.failure)
            XCTAssertEqual(store.canEditSelectedReceipt, receipt.status == .imported)
            XCTAssertEqual(store.canConfirmSelected, receipt.status == .imported)
            if receipt.status != .imported {
                XCTAssertTrue(store.candidates.isEmpty)
                store.selectCandidate(nil)
                XCTAssertFalse(store.hasLinkChoice)
                await store.confirmSelected()
            }
        }
        let confirms = await api.confirms
        XCTAssertTrue(confirms.isEmpty)
    }

    func testCanonicalGroupLabelKeepsRawMerchantKeys() {
        var first = ReviewFixtures.summary(0, shop: "Original")
        var second = ReviewFixtures.summary(1, shop: "original")
        var third = ReviewFixtures.summary(2, shop: "Different")
        second.displayShopName = "Canonical"
        third.displayShopName = "Canonical"

        var groups = ReceiptMerchantGroup.group([first, second, third])
        XCTAssertEqual(groups.map(\.id), ["shop:original", "shop:different"])
        XCTAssertEqual(groups.map(\.name), ["Canonical", "Canonical"])
        XCTAssertEqual(groups.map { $0.receipts.count }, [2, 1])

        first.rawNip = "0000000023"
        second.rawNip = first.rawNip
        third.rawNip = first.rawNip
        third.chainKey = "chain"
        groups = ReceiptMerchantGroup.group([first, second, third])
        XCTAssertEqual(groups.map(\.id), ["nip:0000000023", "chain:chain"])
        XCTAssertEqual(groups.map(\.name), ["Canonical", "Canonical"])
    }

    func testDetailUsesListIssuerOnlyForTheSameVersion() async {
        let api = MockReceiptReviewAPI()
        var summary = ReviewFixtures.summary()
        summary.displayShopName = "Canonical"
        await api.setPage(cursor: nil, receipts: [summary], next: nil)
        await api.setDetail(ReviewFixtures.detail())
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()

        await store.select(summary)
        XCTAssertEqual(store.detail?.summary.shopNameForDisplay, "Canonical")
        await api.setDetail(ReviewFixtures.detail(shop: "Changed", version: 2))
        await store.select(summary)
        XCTAssertEqual(store.detail?.summary.shopNameForDisplay, "Changed")
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

    func testBulkMerchantConfirmsOnlyUnlinkedImportedRowsFromMixedGroup() async throws {
        let api = MockReceiptReviewAPI()
        var receipts = (0...3).map { ReviewFixtures.summary($0) }
        receipts[1].status = .needsReview
        receipts[2].status = .draft
        receipts[3].linked = true
        await api.setPage(cursor: nil, receipts: receipts, next: nil)
        await api.setDetail(ReviewFixtures.detail(), candidates: [ReviewFixtures.candidate()])
        let store = ReceiptReviewStore(api: api, scope: scope)
        await store.load()

        let group = try XCTUnwrap(store.groups.first)
        XCTAssertEqual(group.receipts, receipts)
        XCTAssertTrue(group.canConfirmWithoutLinking)
        await store.confirmMerchant(group)

        let calls = await api.calls
        XCTAssertEqual(calls, [.list(nil), .detail(receipts[0].receiptId), .confirm(receipts[0].receiptId, 1, nil)])
        XCTAssertEqual(store.receipts, Array(receipts.dropFirst()))
        XCTAssertEqual(store.groups.first?.canConfirmWithoutLinking, false)
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
}

private actor ReviewListTransport: ClientTransport {
    let responses: [(status: Int, body: Data)]
    private(set) var requests: [(request: HTTPRequest, body: Data)] = []

    init(_ responses: [(Int, Data)]) {
        self.responses = responses
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let data = try await Data(collecting: XCTUnwrap(body), upTo: 16 * 1024)
        let index = requests.count
        requests.append((request, data))
        guard responses.indices.contains(index) else { throw URLError(.badServerResponse) }
        let reply = responses[index]
        var response = HTTPResponse(status: .init(code: reply.status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody([UInt8](reply.body)))
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
        let page = try await api.listReviewReceipts(cursor: nil, scope: ReviewFixtures.scope)
        XCTAssertEqual(page.receipts.first?.payeeHost, "hestia.example")
        var sent = try XCTUnwrap(listTransport.last)
        XCTAssertEqual(sent.request.method, .post)
        XCTAssertEqual(sent.request.path, "/api/budget/receipts/list")
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(sent.request.headerFields[.cookie])
        XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.65.0")
        let listBody = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(listBody["statuses"] as? [String], ["imported", "needs_review", "draft"])
        XCTAssertNil(listBody["status"])
        XCTAssertEqual(listBody["evidence"] as? String, "exclude")
        XCTAssertEqual(listBody["limit"] as? Int, 200)

        let detailTransport = CapturingTransport(status: 200, body: String(decoding: try ReviewFixtures.data([
            "receipt": ReviewFixtures.detailObject(), "candidates": [ReviewFixtures.candidateObject(strength: "id")],
        ]), as: UTF8.self))
        let detailAPI = try client(detailTransport)
        let detail = try await detailAPI.receiptDetail(id: ReviewFixtures.ids[0], scope: ReviewFixtures.scope)
        XCTAssertEqual(detail.candidates?.first?.matchStrength, .id)
        sent = try XCTUnwrap(detailTransport.last)
        XCTAssertEqual(sent.request.method, .get)
        XCTAssertEqual(sent.request.path, "/api/budget/receipts/detail?receipt_id=\(ReviewFixtures.ids[0])")
        XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(sent.request.headerFields[.cookie])
        XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.60.0")
    }

    func testListPaginatesWithFilterThatIssuedEachCursor() async throws {
        let expectedCursors: [String?] = [nil, "page-two", "page-three"]
        let responseCursors: [Any] = ["page-two", "page-three", NSNull()]
        for olderServer in [false, true] {
            var responses: [(Int, Data)] = []
            if olderServer {
                responses.append((400, Data(#"{"ok":false,"error":"budget_receipt_contract_version_invalid"}"#.utf8)))
            }
            for (index, cursor) in responseCursors.enumerated() {
                responses.append((200, try ReviewFixtures.data([
                    "receipts": [ReviewFixtures.summaryObject(index)], "next_cursor": cursor,
                ])))
            }
            let transport = ReviewListTransport(responses)
            let api = try client(transport)
            let store = ReceiptReviewStore(api: api, scope: ReviewFixtures.scope)
            await store.load()
            XCTAssertNil(store.failure)
            XCTAssertEqual(store.receipts.map(\.receiptId), Array(ReviewFixtures.ids.prefix(3)))

            let requests = await transport.requests
            XCTAssertEqual(requests.count, responses.count)
            let cursors = olderServer ? [nil] + expectedCursors : expectedCursors
            for (index, sent) in requests.prefix(cursors.count).enumerated() {
                let legacyRequest = olderServer && index > 0
                XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!],
                               legacyRequest ? "0.60.0" : "0.65.0")
                XCTAssertEqual(sent.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
                XCTAssertNil(sent.request.headerFields[.cookie])
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
                XCTAssertEqual(body["cursor"] as? String, cursors[index])
                if legacyRequest {
                    XCTAssertNil(body["statuses"])
                    XCTAssertEqual(body["status"] as? String, "imported")
                } else {
                    XCTAssertNil(body["status"])
                    XCTAssertEqual(body["statuses"] as? [String], ["imported", "needs_review", "draft"])
                }
            }
        }
    }

    func testListDoesNotRetryUnrelatedErrorsOrSwitchFilterMidPagination() async throws {
        for (status, code, cursor, expected) in [
            (400, "budget_receipt_invalid_request", nil, ReceiptError.rejected("budget_receipt_invalid_request")),
            (403, "budget_receipt_contract_version_invalid", nil, .forbidden),
            (409, "budget_receipt_contract_version_invalid", nil, .rejected("budget_receipt_contract_version_invalid")),
            (400, "budget_receipt_contract_version_invalid", "next", .unsupportedContractVersion),
        ] {
            let transport = ReviewListTransport([(status, try ReviewFixtures.data(["error": ["code": code]]))])
            let api = try client(transport)
            do {
                _ = try await api.listReviewReceipts(
                    cursor: cursor.map { ReceiptReviewCursor(value: $0, filter: .needsAction) },
                    scope: ReviewFixtures.scope
                )
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ReceiptError, expected)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
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
            XCTAssertEqual(sent.request.headerFields[HTTPField.Name("X-Hestia-Contract-Version")!], "0.60.0")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? NSDictionary)
            var expected: [String: Any] = [
                "receipt_id": ReviewFixtures.ids[0], "expected_version": 4, "receipt_kind": "purchase",
                "receipt_date": "2026-11-22", "receipt_time": NSNull(), "currency": "PLN",
                "total_amount": "12.34", "payment_method": "card", "link": NSNull(),
            ]
            if linked {
                expected["total_amount"] = "15"
                expected["link"] = [
                    "account_id": "account", "entry_reference": "entry-0", "candidate_token": "candidate-0",
                ]
                let lines: [[String: Any]] = [
                    [
                        "line_kind": "item", "raw_name": "Item", "ptu_code": NSNull(), "quantity": "1",
                        "raw_unit": NSNull(), "unit_price_raw": "12.34", "gross_line_total": "12.34",
                        "discount_amount": "0", "net_line_total": "12.34",
                    ],
                    [
                        "line_kind": "item", "raw_name": "Pozostałe / nierozpoznane pozycje", "ptu_code": NSNull(),
                        "quantity": "1", "raw_unit": NSNull(), "unit_price_raw": NSNull(),
                        "gross_line_total": "2.66", "discount_amount": "0", "net_line_total": "2.66",
                    ],
                ]
                expected["lines"] = lines
            }
            XCTAssertEqual(object, expected as NSDictionary)
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
                { _ = try await api.listReviewReceipts(cursor: nil, scope: ReviewFixtures.scope) },
                { _ = try await api.receiptDetail(id: detail.summary.receiptId, scope: ReviewFixtures.scope) },
                { _ = try await api.confirmImportedReceipt(request, scope: ReviewFixtures.scope) },
            ] {
                do { try await call(); XCTFail("Expected the request to be blocked") } catch {}
            }
            XCTAssertNil(transport.last)
        }
    }
}
