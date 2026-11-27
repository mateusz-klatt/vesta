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
        let byID = candidateObject()
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

    func testUnknownReviewMetadataIsDetectedOnEachField() throws {
        let baseline = try XCTUnwrap(listPage(summaryObject()).receipts.first)
        XCTAssertFalse(baseline.hasUnknownReviewMetadata)
        for key in ["status", "source_kind", "document_kind", "gateway_status"] {
            var row = summaryObject()
            row[key] = "future-review-value"
            let summary = try XCTUnwrap(listPage(row).receipts.first)
            XCTAssertTrue(summary.hasUnknownReviewMetadata, key)
        }
    }

    func testTransactionReceiptRequiresKeysAndPreservesExplicitNulls() throws {
        var object = BudgetMappingTests.transactionReceiptObject()
        let nullable = ["shop_name", "total", "currency"]
        for key in nullable { object[key] = NSNull() }
        let data = try JSONSerialization.data(withJSONObject: object)
        let receipt = try JSONDecoder().decode(Components.Schemas.BudgetAnalyticsTransactionReceipt.self, from: data)
        let encoded = try JSONEncoder().encode(receipt)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in nullable { XCTAssertTrue(roundTrip[key] is NSNull, key) }

        for key in object.keys {
            var incomplete = object
            incomplete.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: incomplete)
            XCTAssertThrowsError(try JSONDecoder().decode(Components.Schemas.BudgetAnalyticsTransactionReceipt.self, from: data)) {
                guard case DecodingError.keyNotFound(let missingKey, _) = $0 else {
                    return XCTFail("Expected a missing key error for \(key), got \($0)")
                }
                XCTAssertEqual(missingKey.stringValue, key)
            }
        }
    }

    @MainActor
    func testUnknownFutureEnumValuesDegradeInsteadOfFailing() throws {
        var receipt = summaryObject()
        receipt["status"] = "future-status"
        receipt["source_kind"] = "future-source"
        receipt["document_kind"] = "future-document"
        receipt["gateway_status"] = "future-gateway"
        receipt["receipt_kind"] = "future-receipt-kind"

        var knownReceipt = summaryObject()
        knownReceipt["receipt_id"] = "00000000-0000-0000-0000-000000000002"
        var reviewReceipt = knownReceipt
        reviewReceipt["receipt_id"] = "00000000-0000-0000-0000-000000000004"
        reviewReceipt["status"] = "needs_review"
        var draftReceipt = knownReceipt
        draftReceipt["receipt_id"] = "00000000-0000-0000-0000-000000000005"
        draftReceipt["status"] = "draft"
        let page = try listPage(receipt, knownReceipt, reviewReceipt, draftReceipt)
        XCTAssertEqual(page.receipts.map(\.status), [.unknown, .imported, .needsReview, .draft])
        XCTAssertEqual(page.receipts.map { $0.status.reviewBadge.key }, ["Unknown", "Imported", "Needs review", "Draft"])
        let summary = try XCTUnwrap(page.receipts.first)
        XCTAssertEqual(summary.status, .unknown)
        XCTAssertEqual(summary.sourceKind, .unknown)
        XCTAssertEqual(summary.documentKind, .unknown)
        XCTAssertEqual(summary.gatewayStatus, .unknown)
        XCTAssertEqual(summary.receiptKind, .unknown)
        XCTAssertTrue(summary.hasUnknownReviewMetadata)
        XCTAssertEqual(page.receipts.last?.hasUnknownReviewMetadata, false)

        let line: [String: Any] = [
            "line_no": 1, "line_kind": "future-line-kind", "raw_name": "Test item", "raw_name_key": "test-item",
            "ptu_code": "future-ptu-code", "quantity": "1", "raw_unit": NSNull(), "unit_price_raw": "12.34",
            "gross_line_total": "12.34", "discount_amount": "0", "net_line_total": "12.34",
        ]
        receipt["lines"] = [line]
        receipt["payment_evidence"] = [[
            "receipt_id": "00000000-0000-0000-0000-000000000003", "gateway": NSNull(),
            "gateway_status": "future-gateway", "total_amount": NSNull(), "fee_amount": NSNull(),
            "receipt_date": NSNull(),
        ] as [String: Any]]
        var candidatePayload = candidateObject()
        candidatePayload["amount"] = "-12.34"
        candidatePayload["match_strength"] = "future-strength"
        candidatePayload["credit_debit_indicator"] = "future-indicator"
        let data = try JSONSerialization.data(withJSONObject: ["receipt": receipt, "candidates": [candidatePayload]])
        let result = try JSONDecoder().decode(ReceiptDetailResult.self, from: data)
        XCTAssertEqual(result.receipt.summary, summary)
        let decodedLine = try XCTUnwrap(result.receipt.lines.first)
        XCTAssertEqual(decodedLine.lineKind, .unknown)
        XCTAssertEqual(decodedLine.ptuCode, .unknown)
        XCTAssertEqual(result.receipt.paymentEvidence.first?.gatewayStatus, .unknown)
        let candidate = try XCTUnwrap(result.candidates?.first)
        XCTAssertEqual(candidate.matchStrength, .unknown)
        XCTAssertEqual(candidate.creditDebitIndicator, .unknown)
        XCTAssertEqual(candidate.displayAmount, "12.34")

        let form = ReceiptForm(draft: result.receipt, candidates: [candidate])
        XCTAssertNil(form.candidate)
        XCTAssertNil(form.request(receiptID: summary.receiptId, version: summary.version, candidates: [candidate]))

        let transactionsData = try BudgetMappingTests.transactionsData(rows: [
            ["entry_reference": "unknown-status", "status": "future-booking-status", "currency": "USD",
             "receipt": BudgetMappingTests.transactionReceiptObject(status: "future-status")],
            ["entry_reference": "unknown-direction", "credit_debit_indicator": "future-direction", "currency": "USD"],
            ["entry_reference": "credit", "credit_debit_indicator": "CRDT", "currency": "USD"],
        ])
        let transactionsWire = try JSONDecoder().decode(
            Components.Schemas.BudgetAnalyticsTransactions.self, from: transactionsData
        )
        XCTAssertEqual(transactionsWire.transactions.map(\.status), [.unknown, .book, .book])
        XCTAssertEqual(transactionsWire.transactions.map(\.creditDebitIndicator), [.dbit, .unknown, .crdt])

        let transactions = try BudgetTransactionPage(wire: transactionsWire).transactions
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(transactions.map(\.entryReference), ["unknown-status", "unknown-direction", "credit"])
        XCTAssertEqual(transactions.map { $0.formattedAmount(locale: locale) }, ["-$12.34", "$12.34", "+$12.34"])
        XCTAssertNil(transactions.first { $0.creditDebitIndicator == .unknown }?.signedAmount)

        let receiptWithUnknownStatus = transactions.first?.receipt
        XCTAssertEqual(receiptWithUnknownStatus?.status, .unknown)
        let chip = try XCTUnwrap(BudgetTransactionReceiptChip(receipt: receiptWithUnknownStatus, locale: locale))
        XCTAssertEqual(chip.text, "🧾 Test issuer · $74.50")
        XCTAssertFalse(chip.needsReview)
    }

    private func listPage(_ rows: [String: Any]...) throws -> ReceiptListPage {
        let data = try JSONSerialization.data(withJSONObject: ["receipts": rows, "next_cursor": NSNull()])
        return try JSONDecoder().decode(ReceiptListPage.self, from: data)
    }

    private func decodeLinkedTransaction(_ transaction: [String: Any]) throws -> BudgetReceiptLinkedTransactionWire {
        let data = try JSONSerialization.data(withJSONObject: transaction)
        return try JSONDecoder().decode(Components.Schemas.BudgetReceiptLinkedTransaction.self, from: data)
    }

    private func linkedObject() -> [String: Any] {
        ["account_label": "Test account", "booking_date": "2026-11-24", "amount": "12.34", "currency": "PLN"]
    }

    private func candidateObject() -> [String: Any] {
        [
            "account_id": "test-account", "entry_reference": String(repeating: "a", count: 64), "amount": "12.34",
            "currency": "PLN", "credit_debit_indicator": "DBIT", "transaction_date": NSNull(),
            "booking_date": "2026-11-24", "value_date": NSNull(), "merchant_token_hit": true,
            "match_strength": "id", "date_distance": 0, "candidate_token": "test-token",
        ]
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
