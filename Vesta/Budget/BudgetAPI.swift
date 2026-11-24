import Foundation
import OpenAPIRuntime

protocol BudgetAPI: Sendable {
    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly
    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage
    func status() async throws -> BudgetStatus
}

enum BudgetError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case unavailable
    case failed

    var title: LocalizedStringResource {
        switch self {
        case .unauthorized: APIError.unauthorized.title
        case .forbidden: "Not allowed"
        case .unavailable: "Budget unavailable"
        case .failed: APIError.cannotConnect.title
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .unauthorized: APIError.unauthorized.message
        case .forbidden: "Only an admin can view the household budget."
        case .unavailable: ReceiptError.unavailable.message
        case .failed: APIError.cannotConnect.message
        }
    }

    var errorDescription: String? { String(localized: message) }

    static func from(status: Int) -> BudgetError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404, 503: .unavailable
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
}
