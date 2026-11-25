import Foundation

protocol CalendarAPI: Sendable {
    func agenda(from: Date, to: Date, group: String?, timeZone: TimeZone) async throws -> AgendaPage
}

enum CalendarError: Error, Equatable {
    case unavailable
    case unauthorized
    case forbidden
    case failed(String)

    static func wrap(_ error: any Error) -> CalendarError {
        if let calendar = error as? CalendarError { return calendar }
        switch APIError.wrap(error) {
        case .http(503): return .unavailable
        case .unauthorized, .http(401): return .unauthorized
        case .forbidden, .http(403): return .forbidden
        case let apiError: return .failed(apiError.errorDescription ?? apiError.localizedDescription)
        }
    }
}
