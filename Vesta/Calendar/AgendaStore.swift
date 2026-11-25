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
    private(set) var isDiscarded = false

    private let api: any CalendarAPI
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private let onForbidden: @MainActor () -> Void
    private var generation = 0

    init(api: any CalendarAPI, calendar: Calendar = .current,
         now: @escaping @MainActor () -> Date = { Date() },
         onForbidden: @escaping @MainActor () -> Void = {}) {
        self.api = api
        self.calendar = calendar
        self.now = now
        self.onForbidden = onForbidden
    }

    func load() async {
        guard !isDiscarded else { return }
        generation += 1
        let generation = generation
        // Pull-to-refresh keeps the current list on screen while it reloads.
        if case .loaded = state {} else { state = .loading }
        let from = calendar.startOfDay(for: now())
        let to = calendar.date(byAdding: .day, value: Self.windowDays, to: from)!
        let group = selectedGroup
        do {
            let page = try await api.agenda(from: from, to: to, group: group, timeZone: calendar.timeZone)
            guard !isDiscarded, generation == self.generation else { return }
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
            guard !isDiscarded else { return }
            let error = CalendarError.wrap(error)
            // A denial applies to the whole agenda, even if the requested group changed.
            guard generation == self.generation || error == .forbidden else { return }
            switch error {
            case .forbidden:
                discard()
                onForbidden()
            case .unavailable: state = .unavailable
            case .failed(let message): state = .failed(message)
            }
        }
    }

    func discard() {
        guard !isDiscarded else { return }
        isDiscarded = true
        state = .idle
        groups = []
        selectedGroup = nil
    }

    func refresh() async {
        await load()
    }
}
