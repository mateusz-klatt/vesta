import Foundation
import OpenAPIRuntime

protocol BudgetAPI: Sendable {
    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly
    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage
    func status() async throws -> BudgetStatus
    func overview(period: String, currency: String?) async throws -> BudgetOverview
    func categories() async throws -> [BudgetCategoryDefinition]
    func charts(period: String, currency: String?, history: Int) async throws -> BudgetChartSeries?
}

enum BudgetError: LocalizedError, Equatable {
    case unauthorized
    case expiredDeviceToken
    case revokedDeviceToken
    case invalidDeviceToken
    case forbidden
    case unavailable
    case staleCursor
    case failed

    var title: LocalizedStringResource {
        switch self {
        case .unauthorized, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: APIError.unauthorized.title
        case .forbidden: "Not allowed"
        case .unavailable: "Budget unavailable"
        case .staleCursor, .failed: APIError.cannotConnect.title
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .unauthorized, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: APIError.unauthorized.message
        case .forbidden: "Only an admin can view the household budget."
        case .unavailable: ReceiptError.unavailable.message
        case .staleCursor, .failed: APIError.cannotConnect.message
        }
    }

    var errorDescription: String? { String(localized: message) }

    static func from(status: Int, code: String? = nil) -> BudgetError {
        switch (status, code) {
        case (401, "device_token_expired"): .expiredDeviceToken
        case (401, "device_token_revoked"): .revokedDeviceToken
        case (401, "device_token_invalid"): .invalidDeviceToken
        case (401, _): .unauthorized
        case (403, _): .forbidden
        case (404, _), (503, _): .unavailable
        case (409, "budget_analytics_stale_cursor"): .staleCursor
        default: .failed
        }
    }

    static func wrap(_ error: any Error) -> BudgetError {
        if let budget = error as? BudgetError { return budget }
        if let client = error as? ClientError {
            if let budget = client.underlyingError as? BudgetError { return budget }
            if let status = client.response?.status.code, !(200..<300).contains(status) {
                return from(status: status)
            }
        }
        if let api = error as? APIError, api == .unauthorized { return .unauthorized }
        return .failed
    }

    var isAccessDenial: Bool {
        switch self {
        case .unauthorized, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken, .forbidden: true
        case .unavailable, .staleCursor, .failed: false
        }
    }
}
