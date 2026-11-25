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
    private let onUnauthorized: @MainActor () -> Void
    private var generation = 0

    init(api: any CalendarAPI, calendar: Calendar = .current,
         now: @escaping @MainActor () -> Date = { Date() },
         onForbidden: @escaping @MainActor () -> Void = {},
         onUnauthorized: @escaping @MainActor () -> Void = {}) {
        self.api = api
        self.calendar = calendar
        self.now = now
        self.onForbidden = onForbidden
        self.onUnauthorized = onUnauthorized
    }

    func load() async {
        guard !isDiscarded, !Task.isCancelled else { return }
        let from = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: Self.windowDays, to: from) else { return }
        let to = calendar.startOfDay(for: end)
        generation += 1
        let generation = generation
        // Pull-to-refresh keeps the current list on screen while it reloads.
        if case .loaded = state {} else { state = .loading }
        let group = selectedGroup
        do {
            let page = try await api.agenda(from: from, to: to, group: group, timeZone: calendar.timeZone)
            guard !isDiscarded, generation == self.generation, !Task.isCancelled else { return }
            groups = page.groups
            if let selectedGroup, !groups.contains(selectedGroup) {
                self.selectedGroup = nil
            }
            guard page.enabled else {
                state = .disabled
                return
            }
            let sections = AgendaDay.sections(
                for: page.occurrences, from: from, days: Self.windowDays, calendar: calendar
            )
            state = .loaded(sections: sections, truncated: page.truncated)
        } catch {
            guard !isDiscarded, generation == self.generation, !Task.isCancelled,
                  !APIError.isCancellation(error) else { return }
            switch CalendarError.wrap(error) {
            case .unauthorized:
                discard()
                onUnauthorized()
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
