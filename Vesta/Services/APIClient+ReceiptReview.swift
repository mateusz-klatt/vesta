import OpenAPIRuntime

extension APIClient: ReceiptReviewAPI {
    private static let receiptGroupContract = "0.59.0"

    func listImportedReceipts(cursor: String?, scope: ReceiptSessionScope) async throws -> ReceiptListPage {
        try await review(scope) { client in
            let body = Components.Schemas.BudgetReceiptListRequest(
                cursor: cursor, evidence: "exclude", limit: 200, status: "imported"
            )
            return try await client.listBudgetReceipts(.init(body: .json(body))).ok.body.json
        }
    }

    func listLinkedReceipts(cursor: String?, scope: ReceiptSessionScope) async throws -> ReceiptListPage {
        do {
            return try await review(scope) { client in
                let body = Components.Schemas.BudgetReceiptListRequest(
                    cursor: cursor, linked: true, status: nil
                )
                let headers = Operations.ListBudgetReceipts.Input.Headers(
                    xHestiaContractVersion: Self.receiptGroupContract
                )
                return try await client.listBudgetReceipts(.init(headers: headers, body: .json(body))).ok.body.json
            }
        } catch ReceiptError.rejected("budget_receipt_contract_version_invalid") {
            // Older servers reject a newer contract before listing receipts.
            return .init(receipts: [])
        }
    }

    func receiptDetail(id: String, scope: ReceiptSessionScope, includeGroup: Bool) async throws -> ReceiptDetailResult {
        try await review(scope) { client in
            let input = Operations.GetBudgetReceiptDetail.Input(
                query: .init(receiptId: id),
                headers: .init(xHestiaContractVersion: includeGroup ? Self.receiptGroupContract : nil)
            )
            return try await client.getBudgetReceiptDetail(input).ok.body.json
        }
    }

    func receiptGroupDetail(id: String, scope: ReceiptSessionScope) async throws -> BudgetReceiptGroupDetailResultWire {
        try await review(scope) { client in
            let input = Operations.GetBudgetReceiptGroupDetail.Input(
                query: .init(groupId: id), headers: .init(xHestiaContractVersion: Self.receiptGroupContract)
            )
            return try await client.getBudgetReceiptGroupDetail(input).ok.body.json
        }
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail {
        try await review(scope, requiresMatch: request.link != nil) { client in
            try await client.confirmBudgetReceipt(.init(body: .json(request))).ok.body.json.receipt
        }
    }

    private func review<Value: Sendable>(
        _ scope: ReceiptSessionScope,
        requiresMatch: Bool = false,
        _ operation: (Client) async throws -> Value
    ) async throws -> Value {
        guard receiptReviewEnabled() else { throw ReceiptError.forbidden }
        let client = requestReceiptReviewClient(scope: scope, requiresMatch: requiresMatch)
        do {
            try Task.checkCancellation()
            guard await currentReceiptReviewScope(requiresMatch: requiresMatch) == scope else { throw CancellationError() }
            let value = try await operation(client)
            try Task.checkCancellation()
            guard await currentReceiptReviewScope() == scope else { throw CancellationError() }
            return value
        } catch {
            if APIError.isCancellation(error) { throw CancellationError() }
            try Task.checkCancellation()
            guard await currentReceiptReviewScope(requiresMatch: requiresMatch) == scope else { throw CancellationError() }
            throw ReceiptError.wrap(error)
        }
    }
}
