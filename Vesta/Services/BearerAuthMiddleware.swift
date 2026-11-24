import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Receipt operations use the device token. Native budget reads also use the
/// device token (hestia authz Part C §11, `budget_native_read`), never the login
/// bearer or a cookie; other budget routes never receive either credential.
struct BearerAuthMiddleware: ClientMiddleware {
    let token: @Sendable () -> String?
    var receiptPairing: ReceiptPairing?
    // Unpair can revoke after the active pairing/backend has changed.
    var revoking: ReceiptDeviceToken?
    var budgetEnabled: @Sendable () -> Bool = { false }

    private static let receiptOperations: Set<String> = [
        Operations.ParseBudgetReceiptText.id, Operations.ConfirmBudgetReceipt.id,
        Operations.DeleteBudgetReceipt.id, Operations.RevokeBudgetReceiptDevice.id,
        // The phone does not pin the OpenAPI paths for these read operations.
        "listBudgetReceipts", "searchBudgetReceipts", "getBudgetReceiptDetail", "getBudgetReceiptImage",
    ]
    private static let budgetReadOperations: Set<String> = [
        Operations.GetBudgetAnalyticsMonthlyBudget.id,
        Operations.GetBudgetAnalyticsTransactions.id,
        Operations.GetBudgetStatus.id,
    ]

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        let requiresDevice = Self.receiptOperations.contains(operationID)
        let issuesDeviceToken = operationID == Operations.RedeemBudgetReceiptDevice.id
            || operationID == Operations.LoginBudgetReceiptDevice.id
        if Self.budgetReadOperations.contains(operationID) {
            request.headerFields[.cookie] = nil
            request.headerFields[.authorization] = nil
            guard budgetEnabled() else { throw BudgetError.forbidden }
            // No device token means no request: the session bearer is refused
            // here by hestia, and sending it would widen its use.
            guard let device = await receiptPairing?.credential(for: baseURL) else { throw BudgetError.forbidden }
            request.headerFields[.authorization] = "Bearer \(device.credential.token)"
            let (response, responseBody) = try await next(request, body, baseURL)
            guard response.status.code == 200 else {
                let code = await Self.errorCode(in: responseBody)
                throw BudgetError.from(status: response.status.code, code: code)
            }
            return (response, responseBody)
        }
        guard requiresDevice || issuesDeviceToken else {
            if let path = request.path, path == "/api/budget" || path.hasPrefix("/api/budget/") {
                request.headerFields[.authorization] = nil
                request.headerFields[.cookie] = nil
            } else if let token = token() {
                request.headerFields[.authorization] = "Bearer \(token)"
            }
            return try await next(request, body, baseURL)
        }

        request.headerFields[.cookie] = nil
        request.headerFields[.authorization] = nil
        var pairedDevice: StoredReceiptDeviceToken?
        if requiresDevice {
            if operationID == Operations.RevokeBudgetReceiptDevice.id, let revoking {
                request.headerFields[.authorization] = "Bearer \(revoking.token)"
            } else {
                guard let device = await receiptPairing?.credential(for: baseURL) else { throw ReceiptError.pairAgain }
                pairedDevice = device
                request.headerFields[.authorization] = "Bearer \(device.credential.token)"
            }
        }

        let (response, responseBody) = try await next(request, body, baseURL)
        let status = response.status.code
        guard status != 200 else { return (response, responseBody) }

        // Accept both the pinned flat error and the nested v2 error envelope.
        let code = await Self.errorCode(in: responseBody)
        let error = ReceiptError.from(status: status, code: code)
        if error == .pairAgain, let pairedDevice {
            await receiptPairing?.invalidate(pairedDevice)
        }
        throw error
    }

    private static func errorCode(in body: HTTPBody?) async -> String? {
        guard let body, let data = try? await Data(collecting: body, upTo: 16 * 1024) else { return nil }
        return (try? JSONDecoder().decode(BudgetErrorEnvelope.self, from: data))?.code
    }
}
