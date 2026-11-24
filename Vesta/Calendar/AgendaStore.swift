import Foundation
import Observation

@MainActor
@Observable
final class AgendaStore {
    enum State: Equatable {
        case idle
        case loading
        case loaded(sections: [AgendaDay], truncated: Bool)
        case disabled
        case unavailable
        case failed(String)
    }

    private static let windowDays = 30

    private(set) var state: State = .idle
    var selectedGroup: String?
    private(set) var groups: [String] = []

    private let api: any CalendarAPI
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private var generation = 0

    init(api: any CalendarAPI, calendar: Calendar = .current,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.api = api
        self.calendar = calendar
        self.now = now
    }

    func load() async {
        generation += 1
        let generation = generation
        // Pull-to-refresh keeps the current list on screen while it reloads.
        if case .loaded = state {} else { state = .loading }
        let from = calendar.startOfDay(for: now())
        let to = calendar.date(byAdding: .day, value: Self.windowDays, to: from)!
        let group = selectedGroup
        do {
            let page = try await api.agenda(from: from, to: to, group: group)
            guard generation == self.generation else { return }
            groups = page.groups
            guard page.enabled else {
                state = .disabled
                return
            }
            let sections = AgendaDay.sections(
                for: page.occurrences, from: from, days: Self.windowDays, calendar: calendar
            )
            state = .loaded(sections: sections, truncated: page.truncated)
        } catch {
            guard generation == self.generation else { return }
            switch CalendarError.wrap(error) {
            case .unavailable: state = .unavailable
            case .failed(let message): state = .failed(message)
            }
        }
    }

    func refresh() async {
        await load()
    }
}
