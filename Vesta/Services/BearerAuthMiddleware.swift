import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Receipt operations use the device token. Native budget reads also use the
/// device token (hestia authz Part C §11, `budget_native_read`), never the login
/// bearer or a cookie; other budget routes never receive either credential.
struct BearerAuthMiddleware: ClientMiddleware {
    private let session: BoundSession?
    private let receiptPairing: ReceiptPairing?
    private let receiptScope: ReceiptSessionScope?
    // Unpair can revoke after the active pairing/backend has changed.
    private let revoking: (origin: URL, credential: ReceiptDeviceToken)?
    private let budgetEnabled: @Sendable () -> Bool
    private let receiptReviewEnabled: @Sendable () -> Bool
    private let reviewScoped: Bool
    private let reviewRequiresMatch: Bool

    init(session: BoundSession? = nil,
         receiptPairing: ReceiptPairing? = nil,
         receiptScope: ReceiptSessionScope? = nil,
         revoking: (origin: URL, credential: ReceiptDeviceToken)? = nil,
         budgetEnabled: @escaping @Sendable () -> Bool = { AppConfig.nativeBudgetEnabledForBuild },
         receiptReviewEnabled: @escaping @Sendable () -> Bool = { AppConfig.receiptReviewEnabledForBuild },
         reviewScoped: Bool = false,
         reviewRequiresMatch: Bool = false) {
        self.session = session
        self.receiptPairing = receiptPairing
        self.receiptScope = receiptScope
        self.revoking = revoking
        self.budgetEnabled = budgetEnabled
        self.receiptReviewEnabled = receiptReviewEnabled
        self.reviewScoped = reviewScoped
        self.reviewRequiresMatch = reviewRequiresMatch
    }

    private static let receiptOperations: Set<String> = [
        Operations.ParseBudgetReceiptText.id, Operations.ConfirmBudgetReceipt.id,
        Operations.DeleteBudgetReceipt.id, Operations.RevokeBudgetReceiptDevice.id,
        Operations.ListBudgetReceipts.id, Operations.GetBudgetReceiptDetail.id, Operations.GetBudgetReceiptGroupDetail.id,
        // The phone does not pin the OpenAPI paths for these read operations.
        "searchBudgetReceipts", "getBudgetReceiptImage",
    ]
    private static let receiptReviewOperations: Set<String> = [
        Operations.ListBudgetReceipts.id, Operations.GetBudgetReceiptDetail.id, Operations.GetBudgetReceiptGroupDetail.id,
    ]
    private static let receiptContractHeader = HTTPField.Name("X-Hestia-Contract-Version")!
    private static let budgetReadPaths = [
        Operations.GetBudgetAnalyticsMonthlyBudget.id: "/api/budget/analytics/monthly-budget",
        Operations.GetBudgetAnalyticsTransactions.id: "/api/budget/analytics/transactions",
        Operations.GetBudgetStatus.id: "/api/budget/status",
        Operations.GetBudgetAnalyticsMonthlyBudgetCharts.id: "/api/budget/analytics/monthly-budget/charts",
        Operations.GetBudgetAnalyticsOverview.id: "/api/budget/analytics/overview",
        Operations.GetBudgetAnalyticsCategories.id: "/api/budget/analytics/categories",
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
        let reviewOperation = Self.receiptReviewOperations.contains(operationID)
            || (reviewScoped && operationID == Operations.ConfirmBudgetReceipt.id)
        if reviewOperation {
            guard reviewScoped, receiptScope != nil, receiptReviewEnabled() else { throw ReceiptError.forbidden }
            if request.headerFields[Self.receiptContractHeader] == nil {
                // The original V6 reads and confirm request the gateway evidence contract.
                request.headerFields[Self.receiptContractHeader] = "0.52.0"
            }
        }
        let issuesDeviceToken = operationID == Operations.RedeemBudgetReceiptDevice.id
            || operationID == Operations.LoginBudgetReceiptDevice.id
        if operationID == Operations.ExchangeNativeSession.id {
            request.headerFields[.cookie] = nil
            request.headerFields[.authorization] = nil
            guard request.method == .post, request.path == "/api/auth/device-token",
                  let session, session.actor != nil, !session.token.isEmpty,
                  OriginMatcher.matches(baseURL, session.origin) else { throw DeviceExchangeError.invalidSession }
            request.headerFields[.authorization] = "Bearer \(session.token)"
            let (response, responseBody) = try await next(request, body, baseURL)
            let status = response.status.code
            guard status == 200 else {
                let code = await Self.decodeError(Components.Schemas.AuthError.self, from: responseBody)?.error.code
                throw DeviceExchangeError.http(status: status, code: code)
            }
            return (response, responseBody)
        }
        if let readPath = Self.budgetReadPaths[operationID] {
            request.headerFields[.cookie] = nil
            request.headerFields[.authorization] = nil
            guard request.method == .get,
                  request.path?.split(separator: "?", maxSplits: 1).first.map(String.init) == readPath,
                  budgetEnabled(),
                  let device = await receiptPairing?.nativeBudgetCredential(for: baseURL, session: session),
                  budgetEnabled() else {
                throw BudgetError.forbidden
            }
            try Task.checkCancellation()
            if let receiptScope {
                guard OriginMatcher.matches(baseURL, receiptScope.origin),
                      receiptScope.matches(device, actor: session?.actor ?? device.actor) else {
                    throw CancellationError()
                }
            }
            request.headerFields[.authorization] = "Bearer \(device.credential.token)"
            let (response, responseBody) = try await next(request, body, baseURL)
            guard response.status.code == 200 else {
                let code = await Self.errorCode(in: responseBody)
                throw BudgetError.from(status: response.status.code, code: code)
            }
            return (response, responseBody)
        }
        guard requiresDevice || issuesDeviceToken else {
            request.headerFields[.authorization] = nil
            if let path = request.path, path == "/api/budget" || path.hasPrefix("/api/budget/") {
                request.headerFields[.cookie] = nil
            } else if let session, OriginMatcher.matches(baseURL, session.origin) {
                request.headerFields[.authorization] = "Bearer \(session.token)"
            }
            return try await next(request, body, baseURL)
        }

        request.headerFields[.cookie] = nil
        request.headerFields[.authorization] = nil
        var pairedDevice: StoredReceiptDeviceToken?
        if requiresDevice {
            if operationID == Operations.RevokeBudgetReceiptDevice.id, let revoking {
                guard OriginMatcher.matches(baseURL, revoking.origin) else { throw ReceiptError.pairAgain }
                request.headerFields[.authorization] = "Bearer \(revoking.credential.token)"
            } else {
                let device: StoredReceiptDeviceToken?
                if reviewOperation {
                    device = await receiptPairing?.receiptReviewCredential(
                        for: baseURL, session: session, enabled: receiptReviewEnabled(), requiresMatch: reviewRequiresMatch
                    )
                    guard receiptReviewEnabled(), device != nil else { throw CancellationError() }
                } else {
                    device = await receiptPairing?.credential(for: baseURL, session: session)
                }
                guard let device else { throw ReceiptError.pairAgain }
                if let receiptScope {
                    try Task.checkCancellation()
                    guard OriginMatcher.matches(baseURL, receiptScope.origin),
                          receiptScope.matches(device, actor: session?.actor ?? device.actor) else {
                        throw CancellationError()
                    }
                }
                pairedDevice = device
                request.headerFields[.authorization] = "Bearer \(device.credential.token)"
            }
        }

        let (response, responseBody) = try await next(request, body, baseURL)
        let status = response.status.code
        guard status != 200 else { return (response, responseBody) }

        // Accept both the pinned flat error and the nested v2 error envelope.
        let code = await Self.errorCode(in: responseBody)
        if operationID == Operations.RevokeBudgetReceiptDevice.id, revoking != nil {
            throw DeviceRevocationError.http(status: status, code: code)
        }
        let error = ReceiptError.from(status: status, code: code)
        if receiptScope == nil, error == .expiredDeviceToken || error == .revokedDeviceToken, let pairedDevice {
            await receiptPairing?.invalidate(pairedDevice)
        }
        throw error
    }

    private static func errorCode(in body: HTTPBody?) async -> String? {
        await decodeError(BudgetErrorEnvelope.self, from: body)?.code
    }

    private static func decodeError<Envelope: Decodable>(_ type: Envelope.Type, from body: HTTPBody?) async -> Envelope? {
        guard let body, let data = try? await Data(collecting: body, upTo: 16 * 1024) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
