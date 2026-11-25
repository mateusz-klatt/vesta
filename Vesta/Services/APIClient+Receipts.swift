import OpenAPIRuntime

/// The bearer middleware maps receipt HTTP errors before generated decoding.
extension APIClient: ReceiptsAPI {
    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult {
        let client = requestReceiptClient(scope: scope)
        do {
            let body = Components.Schemas.BudgetReceiptParseTextRequest(sourceKind: source, text: text)
            return try await client.parseBudgetReceiptText(.init(body: .json(body))).ok.body.json
        } catch { throw Self.receiptError(error, scope: scope) }
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail {
        let client = requestReceiptClient(scope: scope)
        do {
            return try await client.confirmBudgetReceipt(.init(body: .json(request))).ok.body.json.receipt
        } catch { throw Self.receiptError(error, scope: scope) }
    }

    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws {
        let client = requestReceiptClient(scope: scope)
        do {
            let input = Operations.DeleteBudgetReceipt.Input(
                body: .json(.init(expectedVersion: expectedVersion, receiptId: id))
            )
            _ = try await client.deleteBudgetReceipt(input).ok
        } catch { throw Self.receiptError(error, scope: scope) }
    }

    private static func receiptError(_ error: any Error, scope: ReceiptSessionScope?) -> any Error {
        if APIError.isCancellation(error) { return CancellationError() }
        let receipt = ReceiptError.wrap(error)
        if scope == nil, receipt == .expiredDeviceToken || receipt == .revokedDeviceToken { return ReceiptError.pairAgain }
        return receipt
    }
}
