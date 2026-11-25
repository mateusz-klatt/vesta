import Foundation
import XCTest

// This target generates its client from the unchanged dd5df46 receipt contract.
final class LegacyReceipts090ContractTests: XCTestCase {
    private let receiptID = "00000000-0000-4000-8000-000000000000"
    private let deviceID = "00000000-0000-4000-8000-111111111111"

    func testLegacyDeviceTokenLoginRedeemAndRevokeBodiesDecode() async throws {
        let token = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG"
        let response = """
        {"token":"\(token)","token_id":"\(deviceID)","scope":"receipts","expires_at":"2027-02-21T18:00:00Z"}
        """
        let client = contractClient([
            "POST /api/budget/receipts/device-token/login": response,
            "POST /api/budget/receipts/device-token/redeem": response,
            "POST /api/budget/receipts/device-token/revoke": #"{"ok":true}"#,
        ])
        let login = try await client.loginBudgetReceiptDevice(.init(body: .json(
            .init(deviceName: "iPhone", password: "fake-password", username: "owner")
        ))).ok.body.json
        let redeem = try await client.redeemBudgetReceiptDevice(.init(body: .json(
            .init(code: "ABCD2345", deviceName: "iPhone")
        ))).ok.body.json
        let revoke = try await client.revokeBudgetReceiptDevice(.init(body: .json(
            .init(tokenId: deviceID)
        ))).ok.body.json

        for result in [login, redeem] {
            XCTAssertEqual(result.token, token)
            XCTAssertEqual(result.tokenId, deviceID)
            XCTAssertEqual(result.scope, .receipts)
            XCTAssertEqual(result.expiresAt.ISO8601Format(), "2027-02-21T18:00:00Z")
        }
        XCTAssertTrue(revoke.ok)
    }

    func testLegacyReceiptParseConfirmAndDeleteBodiesDecode() async throws {
        let client = contractClient([
            "POST /api/budget/receipts/parse-text": """
            {"receipt_id":"\(receiptID)","draft":\(receipt(status: "draft", version: 1)),
             "version":1,"candidates":[{"account_id":"account","entry_reference":"entry","amount":"4.50",
                 "currency":"PLN","credit_debit_indicator":"DBIT","merchant_token_hit":true,
                 "date_distance":0,"candidate_token":"fake-candidate-token","booking_date":null}]}
            """,
            "POST /api/budget/receipts/confirm": """
            {"ok":true,"receipt":\(receipt(status: "confirmed", version: 2))}
            """,
            "POST /api/budget/receipts/delete": #"{"ok":true,"deleted":true}"#,
        ])
        let parse = try await client.parseBudgetReceiptText(.init(body: .json(
            .init(sourceKind: .paste, text: "Sample receipt")
        ))).ok.body.json
        XCTAssertEqual(parse.receiptId, receiptID)
        XCTAssertEqual(parse.draft.status, .draft)
        XCTAssertEqual(parse.draft.totalAmount, "4.50")
        XCTAssertNil(parse.draft.linkedAccountId)
        XCTAssertEqual(parse.candidates.first?.entryReference, "entry")

        let confirm = try await client.confirmBudgetReceipt(.init(body: .json(
            .init(currency: "PLN", expectedVersion: parse.version, lines: [], paymentMethod: .cash,
                  receiptDate: "2026-11-22", receiptId: receiptID, receiptKind: .purchase, totalAmount: "4.50")
        ))).ok.body.json
        XCTAssertTrue(confirm.ok)
        XCTAssertEqual(confirm.receipt.status, .confirmed)
        XCTAssertEqual(confirm.receipt.version, 2)

        let delete = try await client.deleteBudgetReceipt(.init(body: .json(
            .init(expectedVersion: confirm.receipt.version, receiptId: receiptID)
        ))).ok.body.json
        XCTAssertTrue(delete.ok)
        XCTAssertTrue(delete.deleted)
    }

    private func receipt(status: String, version: Int) -> String {
        """
        {"receipt_id":"\(receiptID)","receipt_kind":"purchase","status":"\(status)","source_kind":"live_text",
         "linked":false,"linked_account_id":null,"linked_entry_ref":null,"version":\(version),
         "created_at":1795400000.0,"updated_at":1795400000.0,"image_available":false,"lines":[],
         "receipt_date":"2026-11-22","total_amount":"4.50","currency":"PLN","payment_method":"cash"}
        """
    }
}
