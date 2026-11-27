import Foundation
import XCTest
@testable import Vesta

final class ReceiptGroupPresentationTests: XCTestCase {
    private let group = ReceiptLinkGroupRefWire(groupId: "00000000-0000-0000-0000-000000000001", memberCount: 2)

    func testBadgeIsHiddenWithoutAGroupReference() {
        let receipt = ImportedReceiptSummary(receiptId: "00000000-0000-0000-0000-000000000002", linked: true)
        XCTAssertNil(ReceiptGroupBadgeContent(group: receipt.linkGroup, members: [receipt]))
    }

    func testBadgeShowsMemberCountWithIncompleteListAndTotalWithCompleteList() throws {
        let first = member(2, shop: "Bakery", total: "12.34")
        let second = member(3, shop: "Coffee Shop", total: "6.78")
        let partial = try XCTUnwrap(ReceiptGroupBadgeContent(group: first.linkGroup, members: [first]))
        XCTAssertEqual(partial.groupID, group.groupId)
        XCTAssertEqual(partial.memberCount, 2)
        XCTAssertNil(partial.total)

        let complete = try XCTUnwrap(ReceiptGroupBadgeContent(group: first.linkGroup, members: [first, second]))
        XCTAssertEqual(complete.total?.amount, Decimal(string: "19.12"))
        XCTAssertEqual(complete.total?.currency, "PLN")
    }

    func testBadgeDoesNotAddIncompatibleOrStaleTotals() {
        let first = member(2, shop: "Bakery", total: "12.34")
        var second = member(3, shop: "Coffee Shop", total: "6.78")
        second.currency = "EUR"
        XCTAssertNil(ReceiptGroupBadgeContent(group: group, members: [first, second])?.total)

        second.currency = "PLN"
        second.linkGroup = .init(groupId: group.groupId, groupVersion: 2, memberCount: 2)
        XCTAssertNil(ReceiptGroupBadgeContent(group: group, members: [first, second])?.total)
    }

    func testSheetShowsMemberDetailsAndSeparatePaymentEvidence() {
        let first = member(2, shop: "Bakery", total: "12.34")
        let second = member(3, shop: "Coffee Shop", total: "6.78")
        let evidence = member(4, shop: "Payment Service", total: "19.12")
        let transactionReference = String(repeating: "a", count: 64)
        let content = ReceiptGroupSheetContent(.init(
            group: group, members: [first, second], evidence: evidence,
            linkedAccountId: "test-account", linkedEntryRef: transactionReference
        ))

        XCTAssertEqual(content.transactionReference, transactionReference)
        XCTAssertEqual(content.memberCount, 2)
        XCTAssertEqual(content.total?.amount, Decimal(string: "19.12"))
        XCTAssertEqual(content.members.map(\.shop), ["Bakery", "Coffee Shop"])
        XCTAssertEqual(content.members.map(\.date), ["2026-11-22", "2026-11-22"])
        XCTAssertEqual(content.members.map(\.total), ["12.34", "6.78"])
        XCTAssertEqual(content.members.map(\.currency), ["PLN", "PLN"])
        XCTAssertEqual(content.evidence?.id, evidence.receiptId)
        XCTAssertEqual(content.evidence?.shop, "Payment Service")
        XCTAssertEqual(content.evidence?.date, "2026-11-22")
        XCTAssertEqual(content.evidence?.total, "19.12")
    }

    func testSheetOmitsMissingEvidenceAndTransactionReference() {
        let content = ReceiptGroupSheetContent(.init(group: group, members: []))
        XCTAssertNil(content.evidence)
        XCTAssertNil(content.transactionReference)
        XCTAssertNil(content.total)
    }

    private func member(_ number: Int, shop: String, total: String) -> ImportedReceiptSummary {
        .init(receiptId: "00000000-0000-0000-0000-00000000000\(number)", rawShopName: shop,
              receiptDate: "2026-11-22", totalAmount: total, currency: "PLN", status: .confirmed,
              linked: true, linkGroup: group)
    }
}
