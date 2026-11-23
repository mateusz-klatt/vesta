import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Selects the credential for each endpoint. Receipt operations require the
/// paired device token. The rest use the bearer issued by native login.
struct BearerAuthMiddleware: ClientMiddleware {
    let token: @Sendable () -> String?
    var receiptPairing: ReceiptPairing?

    private static let receiptOperations: Set<String> = [
        "parseBudgetReceiptText", "confirmBudgetReceipt", "deleteBudgetReceipt",
    ]

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if Self.receiptOperations.contains(operationID) {
            guard let receiptPairing, let device = await receiptPairing.credential(for: baseURL) else {
                throw ReceiptError.pairAgain
            }
            request.headerFields[.authorization] = "Bearer \(device.credential.token)"
            request.headerFields[.cookie] = nil
            let (response, responseBody) = try await next(request, body, baseURL)
            let status = response.status.code
            guard status != 200 else { return (response, responseBody) }

            // Decode before the generated client, which only knows the flat v1 error shape.
            let code = await Self.errorCode(in: responseBody)
            let error = ReceiptError.from(status: status, code: code)
            if error == .pairAgain { await receiptPairing.invalidate(device) }
            throw error
        }
        if let token = token() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }

    private static func errorCode(in body: HTTPBody?) async -> String? {
        guard let body, let data = try? await Data(collecting: body, upTo: 16 * 1024) else { return nil }
        return (try? JSONDecoder().decode(BudgetErrorEnvelope.self, from: data))?.code
    }
}
