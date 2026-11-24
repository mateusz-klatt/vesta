import Foundation

protocol CalendarAPI: Sendable {
    func agenda(from: Date, to: Date, group: String?) async throws -> AgendaPage
}

enum CalendarError: Error, Equatable {
    case unavailable
    case failed(String)

    static func wrap(_ error: any Error) -> CalendarError {
        if let calendar = error as? CalendarError { return calendar }
        switch APIError.wrap(error) {
        case .http(503): return .unavailable
        case let apiError: return .failed(apiError.errorDescription ?? apiError.localizedDescription)
        }
    }
}

// TODO(hestia instances endpoint): Conform APIClient to CalendarAPI and map the
// expanded instances once GET /api/calendars/instances is added to the OpenAPI spec.
