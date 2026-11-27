import Foundation
import XCTest
@testable import Vesta

final class ReceiptContract060Tests: XCTestCase {
    private let receiptID = "00000000-0000-0000-0000-000000000001"

    func testListDecodesLinkedTransactionAndIgnoresOtherDeployedFields() throws {
        var row = summaryObject()
        row["linked"] = true
        row["linked_transaction"] = linkedObject()
        row["card_last4"] = "1234"
        row["link_group"] = [
            "group_id": "00000000-0000-0000-0000-000000000002", "group_status": "confirmed",
            "group_version": 1, "member_count": 1, "fee_amount": NSNull(), "evidence_receipt_id": NSNull(),
        ] as [String: Any]

        let summary = try XCTUnwrap(listPage(row).receipts.first)
        XCTAssertEqual(summary.receiptId, receiptID)
        XCTAssertTrue(summary.linked)
        let transaction = try XCTUnwrap(summary.linkedTransaction)
        XCTAssertEqual(transaction.accountLabel, "Test account")
        XCTAssertEqual(transaction.bookingDate, "2026-11-24")
        XCTAssertEqual(transaction.amount, "12.34")
        XCTAssertEqual(transaction.currency, "PLN")
    }

    func testListAcceptsNullOrOmittedLinkedTransaction() throws {
        let legacyRow = summaryObject()
        var rowWithNull = legacyRow
        rowWithNull["linked_transaction"] = NSNull()

        for row in [rowWithNull, legacyRow] {
            let summary = try XCTUnwrap(listPage(row).receipts.first)
            XCTAssertNil(summary.linkedTransaction)
        }
    }

    func testDetailAcceptsNullOrOmittedLinkedTransaction() throws {
        var receipt = summaryObject()
        receipt["linked"] = true
        receipt["lines"] = []
        var receiptWithNull = receipt
        receiptWithNull["linked_transaction"] = NSNull()

        for object in [receiptWithNull, receipt] {
            let data = try JSONSerialization.data(withJSONObject: ["receipt": object])
            let detail = try JSONDecoder().decode(ReceiptDetailResult.self, from: data)
            XCTAssertTrue(detail.receipt.summary.linked)
            XCTAssertNil(detail.receipt.summary.linkedTransaction)
        }
    }

    func testLinkedTransactionPreservesExplicitNulls() throws {
        let value: [String: Any] = [
            "account_label": "Test account", "booking_date": NSNull(), "amount": NSNull(), "currency": NSNull(),
        ]
        let transaction = try decodeLinkedTransaction(value)
        XCTAssertEqual(transaction.accountLabel, "Test account")
        XCTAssertNil(transaction.bookingDate)
        XCTAssertNil(transaction.amount)
        XCTAssertNil(transaction.currency)

        let encoded = try JSONEncoder().encode(transaction)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertTrue(object["booking_date"] is NSNull)
        XCTAssertTrue(object["amount"] is NSNull)
        XCTAssertTrue(object["currency"] is NSNull)
    }

    func testLinkedTransactionRequiresEveryKeyAndNonNullAccountLabel() throws {
        for key in ["account_label", "booking_date", "amount", "currency"] {
            var value = linkedObject()
            value.removeValue(forKey: key)
            XCTAssertThrowsError(try decodeLinkedTransaction(value)) { error in
                guard case DecodingError.keyNotFound(let missingKey, _) = error else {
                    return XCTFail("Expected a missing key error for \(key), got \(error)")
                }
                XCTAssertEqual(missingKey.stringValue, key)
            }
        }

        var value = linkedObject()
        value["account_label"] = NSNull()
        XCTAssertThrowsError(try decodeLinkedTransaction(value))
    }

    func testDetailDecodesIDAndAnUnknownStrengthInSameResponse() throws {
        let byID: [String: Any] = [
            "account_id": "test-account", "entry_reference": String(repeating: "a", count: 64), "amount": "12.34",
            "currency": "PLN", "credit_debit_indicator": "DBIT", "transaction_date": NSNull(),
            "booking_date": "2026-11-24", "value_date": NSNull(), "merchant_token_hit": true,
            "match_strength": "id", "date_distance": 0, "candidate_token": "test-token",
        ]
        var unknown = byID
        unknown["entry_reference"] = String(repeating: "b", count: 64)
        unknown["match_strength"] = "other-strength"

        var receipt = summaryObject()
        receipt["lines"] = []
        var group = byID
        group.removeValue(forKey: "merchant_token_hit")
        group["evidence_fingerprint"] = "test-fingerprint"
        group["fee_amount"] = NSNull()
        group["evidence_receipt_id"] = NSNull()
        group["members_sum"] = "12.34"
        group["member_receipt_ids"] = [receiptID]
        group["member_receipts"] = [summaryObject()]
        let data = try JSONSerialization.data(withJSONObject: [
            "receipt": receipt, "candidates": [byID, unknown], "group_candidates": [group], "no_bank_data": false,
        ])

        let decoder = JSONDecoder()
        let detail = try decoder.decode(ReceiptDetailResult.self, from: data)
        XCTAssertEqual(detail.candidates?.map(\.matchStrength), [.id, .unknown])

        var invalid = byID
        invalid["match_strength"] = 42
        XCTAssertThrowsError(try decoder.decode(
            ReceiptCandidate.self, from: JSONSerialization.data(withJSONObject: invalid)
        ))
    }

    func testUnknownReviewMetadataDoesNotBreakSummaryOrEvidenceDecoding() throws {
        let baseline = try XCTUnwrap(listPage(summaryObject()).receipts.first)
        XCTAssertFalse(baseline.hasUnknownReviewMetadata)
        for key in ["status", "source_kind", "document_kind", "gateway_status"] {
            var row = summaryObject()
            row[key] = "other-review-value"
            let summary = try XCTUnwrap(listPage(row).receipts.first)
            XCTAssertTrue(summary.hasUnknownReviewMetadata, key)
        }

        var receipt = summaryObject()
        receipt["status"] = "other-status"
        receipt["source_kind"] = "other-source"
        receipt["document_kind"] = "other-document"
        receipt["gateway_status"] = "other-gateway"
        receipt["lines"] = []
        receipt["payment_evidence"] = [[
            "receipt_id": "00000000-0000-0000-0000-000000000002", "gateway": NSNull(),
            "gateway_status": "other-gateway", "total_amount": NSNull(), "fee_amount": NSNull(), "receipt_date": NSNull(),
        ] as [String: Any]]
        let detail = try JSONDecoder().decode(
            ReceiptDetail.self, from: JSONSerialization.data(withJSONObject: receipt)
        )
        XCTAssertEqual(detail.summary.status, .unknown)
        XCTAssertEqual(detail.summary.sourceKind, .unknown)
        XCTAssertEqual(detail.summary.documentKind, .unknown)
        XCTAssertEqual(detail.summary.gatewayStatus, .unknown)
        XCTAssertEqual(detail.paymentEvidence.first?.gatewayStatus, .unknown)
    }

    private func listPage(_ row: [String: Any]) throws -> ReceiptListPage {
        let data = try JSONSerialization.data(withJSONObject: ["receipts": [row], "next_cursor": NSNull()])
        return try JSONDecoder().decode(ReceiptListPage.self, from: data)
    }

    private func decodeLinkedTransaction(_ transaction: [String: Any]) throws -> BudgetReceiptLinkedTransactionWire {
        let data = try JSONSerialization.data(withJSONObject: transaction)
        return try JSONDecoder().decode(Components.Schemas.BudgetReceiptLinkedTransaction.self, from: data)
    }

    private func linkedObject() -> [String: Any] {
        ["account_label": "Test account", "booking_date": "2026-11-24", "amount": "12.34", "currency": "PLN"]
    }

    private func summaryObject() -> [String: Any] {
        [
            "receipt_id": receiptID, "shop_id": NSNull(), "chain_key": NSNull(), "raw_shop_name": "Test shop",
            "raw_nip": NSNull(), "receipt_kind": "purchase", "receipt_date": "2026-11-23", "receipt_time": NSNull(),
            "total_amount": "12.34", "currency": "PLN", "payment_method": "card", "status": "imported",
            "source_kind": "email", "linked": false, "linked_account_id": NSNull(), "linked_entry_ref": NSNull(),
            "version": 1, "created_at": 0, "updated_at": 0, "image_available": false,
            "image_expires_at": NSNull(), "raw_text_expires_at": NSNull(), "math_delta": NSNull(),
        ]
    }
}
