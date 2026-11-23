import OpenAPIRuntime

/// The bearer middleware maps receipt HTTP errors before generated decoding.
extension APIClient: ReceiptsAPI {
    func parseReceiptText(_ text: String) async throws -> ReceiptParseResult {
        refresh()
        do {
            return try await client.parseBudgetReceiptText(.init(body: .json(.init(text: text)))).ok.body.json
        } catch { throw ReceiptError.wrap(error) }
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        refresh()
        do {
            return try await client.confirmBudgetReceipt(.init(body: .json(request))).ok.body.json.receipt
        } catch { throw ReceiptError.wrap(error) }
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        refresh()
        do {
            let input = Operations.DeleteBudgetReceipt.Input(
                body: .json(.init(expectedVersion: expectedVersion, receiptId: id))
            )
            _ = try await client.deleteBudgetReceipt(input).ok
        } catch { throw ReceiptError.wrap(error) }
    }
}
