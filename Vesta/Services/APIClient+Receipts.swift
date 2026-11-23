import Foundation
import OpenAPIRuntime

/// Receipts v1a calls on the shared, bearer-authenticated client. Every non-200
/// answer carries (or, from middleware, may omit) a `BudgetError` body;
/// ``ReceiptError/from(status:code:)`` turns status + code into user copy.
extension APIClient: ReceiptsAPI {

    func parseReceiptText(_ text: String) async throws -> ReceiptParseResult {
        refresh()
        do {
            switch try await client.parseBudgetReceiptText(.init(body: .json(.init(text: text)))) {
            case .ok(let ok): return try ok.body.json
            case .badRequest(let r): throw Self.fail(400, try? r.body.json)
            case .unauthorized(let r): throw Self.fail(401, try? r.body.json)
            case .forbidden(let r): throw Self.fail(403, try? r.body.json)
            case .notFound(let r): throw Self.fail(404, try? r.body.json)
            case .conflict(let r): throw Self.fail(409, try? r.body.json)
            case .lengthRequired(let r): throw Self.fail(411, try? r.body.json)
            case .contentTooLarge(let r): throw Self.fail(413, try? r.body.json)
            case .unsupportedMediaType(let r): throw Self.fail(415, try? r.body.json)
            case .internalServerError(let r): throw Self.fail(500, try? r.body.json)
            case .serviceUnavailable(let r): throw Self.fail(503, try? r.body.json)
            case .undocumented(let code, _): throw Self.fail(code, nil)
            }
        } catch { throw ReceiptError.wrap(error) }
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        refresh()
        do {
            switch try await client.confirmBudgetReceipt(.init(body: .json(request))) {
            case .ok(let ok): return try ok.body.json.receipt
            case .badRequest(let r): throw Self.fail(400, try? r.body.json)
            case .unauthorized(let r): throw Self.fail(401, try? r.body.json)
            case .forbidden(let r): throw Self.fail(403, try? r.body.json)
            case .notFound(let r): throw Self.fail(404, try? r.body.json)
            case .conflict(let r): throw Self.fail(409, try? r.body.json)
            case .lengthRequired(let r): throw Self.fail(411, try? r.body.json)
            case .contentTooLarge(let r): throw Self.fail(413, try? r.body.json)
            case .unsupportedMediaType(let r): throw Self.fail(415, try? r.body.json)
            case .internalServerError(let r): throw Self.fail(500, try? r.body.json)
            case .serviceUnavailable(let r): throw Self.fail(503, try? r.body.json)
            case .undocumented(let code, _): throw Self.fail(code, nil)
            }
        } catch { throw ReceiptError.wrap(error) }
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        refresh()
        do {
            let input = Operations.DeleteBudgetReceipt.Input(
                body: .json(.init(expectedVersion: expectedVersion, receiptId: id))
            )
            switch try await client.deleteBudgetReceipt(input) {
            case .ok: return
            case .badRequest(let r): throw Self.fail(400, try? r.body.json)
            case .unauthorized(let r): throw Self.fail(401, try? r.body.json)
            case .forbidden(let r): throw Self.fail(403, try? r.body.json)
            case .notFound(let r): throw Self.fail(404, try? r.body.json)
            case .conflict(let r): throw Self.fail(409, try? r.body.json)
            case .lengthRequired(let r): throw Self.fail(411, try? r.body.json)
            case .contentTooLarge(let r): throw Self.fail(413, try? r.body.json)
            case .unsupportedMediaType(let r): throw Self.fail(415, try? r.body.json)
            case .internalServerError(let r): throw Self.fail(500, try? r.body.json)
            case .serviceUnavailable(let r): throw Self.fail(503, try? r.body.json)
            case .undocumented(let code, _): throw Self.fail(code, nil)
            }
        } catch { throw ReceiptError.wrap(error) }
    }

    private static func fail(_ status: Int, _ body: Components.Schemas.BudgetError?) -> ReceiptError {
        ReceiptError.from(status: status, code: body?.error)
    }
}
