import OpenAPIRuntime

extension APIClient: ReceiptReviewAPI {
    func listReviewReceipts(
        cursor: ReceiptReviewCursor?, firstPageFilter: ReceiptReviewListFilter, scope: ReceiptSessionScope
    ) async throws -> ReceiptReviewPage {
        let filter = cursor?.filter ?? firstPageFilter
        return try await review(scope, listFilter: filter) { client in
            let body: Components.Schemas.BudgetReceiptListRequest = switch filter {
            case .needsAction:
                .init(cursor: cursor?.value, statuses: ["imported", "needs_review", "draft"])
            case .imported:
                .init(cursor: cursor?.value, status: "imported")
            }
            let page = try await client.listBudgetReceipts(.init(body: .json(body))).ok.body.json
            return ReceiptReviewPage(
                receipts: page.receipts,
                nextCursor: page.nextCursor.map { ReceiptReviewCursor(value: $0, filter: filter) }
            )
        }
    }

    func receiptDetail(id: String, scope: ReceiptSessionScope) async throws -> ReceiptDetailResult {
        try await review(scope, listFilter: nil) { client in
            let input = Operations.GetBudgetReceiptDetail.Input(query: .init(receiptId: id))
            return try await client.getBudgetReceiptDetail(input).ok.body.json
        }
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail {
        try await review(scope, requiresMatch: request.link != nil, listFilter: nil) { client in
            try await client.confirmBudgetReceipt(.init(body: .json(request))).ok.body.json.receipt
        }
    }

    private func review<Value: Sendable>(
        _ scope: ReceiptSessionScope,
        requiresMatch: Bool = false,
        listFilter: ReceiptReviewListFilter?,
        _ operation: (Client) async throws -> Value
    ) async throws -> Value {
        guard receiptReviewEnabled() else { throw ReceiptError.forbidden }
        let client = requestReceiptReviewClient(scope: scope, requiresMatch: requiresMatch, listFilter: listFilter)
        do {
            try Task.checkCancellation()
            guard await currentReceiptReviewScope(requiresMatch: requiresMatch) == scope else { throw CancellationError() }
            let value = try await operation(client)
            try Task.checkCancellation()
            guard await currentReceiptReviewScope() == scope else { throw CancellationError() }
            return value
        } catch {
            if APIError.isCancellation(error) { throw CancellationError() }
            guard await currentReceiptReviewScope(requiresMatch: requiresMatch) == scope else { throw CancellationError() }
            throw ReceiptError.wrap(error)
        }
    }
}
