import Foundation
import XCTest
@testable import Vesta

final class ReceiptGroupWireTests: XCTestCase {
    private let groupID = "10000000-0000-0000-0000-000000000001"
    private let firstReceiptID = "20000000-0000-0000-0000-000000000001"
    private let secondReceiptID = "20000000-0000-0000-0000-000000000002"
    private let evidenceReceiptID = "20000000-0000-0000-0000-000000000003"

    func testGroupDetailDecodesMembersAndNullEvidence() throws {
        let detail = try decodeGroup(detailObject())

        XCTAssertEqual(detail.group.groupId, groupID)
        XCTAssertEqual(detail.group.groupStatus, .confirmed)
        XCTAssertEqual(detail.group.groupVersion, 1)
        XCTAssertEqual(detail.group.memberCount, 2)
        XCTAssertNil(detail.group.feeAmount)
        XCTAssertNil(detail.group.evidenceReceiptId)
        XCTAssertEqual(detail.members.map(\.receiptId), [firstReceiptID, secondReceiptID])
        XCTAssertEqual(detail.members.map(\.rawShopName), ["Fixture Market", "Fixture Bakery"])
        XCTAssertEqual(detail.members.map(\.receiptDate), ["2026-11-22", "2026-11-22"])
        XCTAssertEqual(detail.members.map(\.totalAmount), ["10.20", "2.14"])
        XCTAssertEqual(detail.members.first?.linkGroup, detail.group)
        XCTAssertNil(detail.members.last?.linkGroup)
        XCTAssertNil(detail.evidence)
        XCTAssertNil(detail.linkedAccountId)
        XCTAssertNil(detail.linkedEntryRef)
    }

    func testGroupDetailDecodesEvidenceAndBankReferenceWhenPresent() throws {
        var object = detailObject()
        var group = groupObject()
        group["evidence_receipt_id"] = evidenceReceiptID
        group["fee_amount"] = "0.25"
        object["group"] = group
        var evidence = summaryObject(id: evidenceReceiptID, shop: "Fixture Payments", total: "12.59")
        evidence["document_kind"] = "payment_confirmation"
        object["evidence"] = evidence
        object["linked_account_id"] = "fixture-account"
        object["linked_entry_ref"] = String(repeating: "a", count: 64)

        let detail = try decodeGroup(object)

        XCTAssertEqual(detail.group.evidenceReceiptId, evidenceReceiptID)
        XCTAssertEqual(detail.group.feeAmount, "0.25")
        XCTAssertEqual(detail.evidence?.receiptId, evidenceReceiptID)
        XCTAssertEqual(detail.evidence?.documentKind, .paymentConfirmation)
        XCTAssertEqual(detail.linkedAccountId, "fixture-account")
        XCTAssertEqual(detail.linkedEntryRef, String(repeating: "a", count: 64))
    }

    func testGroupRequiresNullableKeysAtBothLevels() throws {
        for key in ["evidence", "linked_account_id", "linked_entry_ref"] {
            var object = detailObject()
            object.removeValue(forKey: key)
            assertMissingKey(key, in: object)
        }
        for key in ["fee_amount", "evidence_receipt_id"] {
            var object = detailObject()
            var group = groupObject()
            group.removeValue(forKey: key)
            object["group"] = group
            assertMissingKey(key, in: object)
        }
    }

    func testReceiptListAndDetailDecodeOptionalGroupReference() throws {
        var grouped = summaryObject(id: firstReceiptID, shop: "Fixture Market", total: "10.20")
        grouped["link_group"] = groupObject()
        var nullGroup = summaryObject(id: secondReceiptID, shop: "Fixture Bakery", total: "2.14")
        nullGroup["link_group"] = NSNull()
        let missingGroup = summaryObject(id: evidenceReceiptID, shop: "Fixture Payments", total: "12.34")
        let list = try JSONDecoder().decode(ReceiptListPage.self, from: data([
            "receipts": [grouped, nullGroup, missingGroup], "next_cursor": NSNull(),
        ]))

        XCTAssertEqual(list.receipts.map { $0.linkGroup?.groupId }, [groupID, nil, nil])

        grouped["lines"] = []
        let detail = try JSONDecoder().decode(ReceiptDetailResult.self, from: data(["receipt": grouped]))
        XCTAssertEqual(detail.receipt.summary.linkGroup?.groupId, groupID)
    }

    private func assertMissingKey(_ key: String, in object: [String: Any], line: UInt = #line) {
        XCTAssertThrowsError(try decodeGroup(object), line: line) { error in
            guard case DecodingError.keyNotFound(let missing, _) = error else {
                return XCTFail("Expected a missing key error for \(key), got \(error)", line: line)
            }
            XCTAssertEqual(missing.stringValue, key, line: line)
        }
    }

    private func decodeGroup(_ object: [String: Any]) throws -> Components.Schemas.BudgetReceiptGroupDetailResult {
        try JSONDecoder().decode(Components.Schemas.BudgetReceiptGroupDetailResult.self, from: data(object))
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func detailObject() -> [String: Any] {
        var first = summaryObject(id: firstReceiptID, shop: "Fixture Market", total: "10.20")
        first["link_group"] = groupObject()
        return [
            "group": groupObject(),
            "members": [first, summaryObject(id: secondReceiptID, shop: "Fixture Bakery", total: "2.14")],
            "evidence": NSNull(), "linked_account_id": NSNull(), "linked_entry_ref": NSNull(),
        ]
    }

    private func groupObject() -> [String: Any] {
        [
            "group_id": groupID, "group_status": "confirmed", "group_version": 1, "member_count": 2,
            "fee_amount": NSNull(), "evidence_receipt_id": NSNull(),
        ]
    }

    private func summaryObject(id: String, shop: String, total: String) -> [String: Any] {
        [
            "receipt_id": id, "shop_id": NSNull(), "chain_key": NSNull(), "raw_shop_name": shop,
            "raw_nip": NSNull(), "receipt_kind": "purchase", "receipt_date": "2026-11-22",
            "receipt_time": NSNull(), "total_amount": total, "currency": "PLN", "payment_method": "card",
            "status": "confirmed", "source_kind": "email", "linked": true, "linked_account_id": NSNull(),
            "linked_entry_ref": NSNull(), "version": 1, "created_at": 0, "updated_at": 0,
            "image_available": false, "image_expires_at": NSNull(), "raw_text_expires_at": NSNull(),
            "math_delta": NSNull(),
        ]
    }
}
