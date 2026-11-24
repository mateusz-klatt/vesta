import Foundation
import XCTest
@testable import Vesta

private func warsawCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
}

private func localDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    warsawCalendar().date(from: DateComponents(year: year, month: month, day: day))!
}

private func allDayOccurrence(_ id: String, _ start: String, _ end: String,
                              summary: String? = nil,
                              status: AgendaOccurrence.Status = .confirmed) -> AgendaOccurrence {
    AgendaOccurrence(
        eventID: id, group: "home", summary: summary ?? id,
        start: AgendaTime(date: start)!, end: AgendaTime(date: end)!,
        allDay: true, status: status
    )
}

private func timedOccurrence(_ id: String, _ start: String, _ end: String,
                             summary: String? = nil,
                             status: AgendaOccurrence.Status = .confirmed) -> AgendaOccurrence {
    AgendaOccurrence(
        eventID: id, group: "home", summary: summary ?? id,
        start: AgendaTime(dateTime: start)!, end: AgendaTime(dateTime: end)!,
        allDay: false, status: status
    )
}

final class AgendaTimeParsingTests: XCTestCase {
    func testAllDayDateParsing() {
        XCTAssertEqual(AgendaTime(date: "2026-11-24"), .allDay(year: 2026, month: 11, day: 24))
        XCTAssertNil(AgendaTime(date: "2026-02-30"))
        XCTAssertNil(AgendaTime(date: "24-11-2026"))
    }

    func testZAndOffsetParsing() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = utc.date(from: DateComponents(
            year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5
        ))!
        for raw in ["2026-01-02T03:04:05Z", "2026-01-02T05:04:05+02:00", "2026-01-02T01:04:05-02:00"] {
            let parsed = try XCTUnwrap(AgendaTime(dateTime: raw), raw)
            guard case let .instant(date) = parsed else { XCTFail(raw); return }
            XCTAssertEqual(date, expected, raw)
        }
    }

    func testFractionalSeconds() throws {
        let whole = try XCTUnwrap(AgendaTime(dateTime: "2026-01-02T03:04:05Z"))
        let fractional = try XCTUnwrap(AgendaTime(dateTime: "2026-01-02T03:04:05.123456Z"))
        guard case let .instant(wholeDate) = whole, case let .instant(fractionalDate) = fractional else {
            XCTFail("Expected instants")
            return
        }
        XCTAssertEqual(fractionalDate.timeIntervalSince(wholeDate), 0.123456, accuracy: 0.000001)
    }

    func testTimeZoneOnlyUsesNamedZone() throws {
        let parsed = try XCTUnwrap(AgendaTime(
            dateTime: "2026-07-01T12:00:00", timeZone: "Europe/Warsaw"
        ))
        let expected = try XCTUnwrap(AgendaTime(dateTime: "2026-07-01T10:00:00Z"))
        XCTAssertEqual(parsed, expected)
    }

    func testGarbageAndMissingZoneAreRejected() {
        for raw in ["not a date", "2026-01-02", "2026-13-02T03:04:05Z", "2026-01-02T25:04:05Z"] {
            XCTAssertNil(AgendaTime(dateTime: raw), raw)
        }
        XCTAssertNil(AgendaTime(dateTime: "2026-01-02T03:04:05"))
        XCTAssertNil(AgendaTime(dateTime: "2026-01-02T03:04:05", timeZone: "Not/AZone"))
        XCTAssertNil(AgendaTime(dateTime: "2026-03-29T02:30:00", timeZone: "Europe/Warsaw"))
    }

    func testOccurrenceIDUsesRecurrenceIDOrStart() {
        let start = AgendaTime(dateTime: "2026-01-02T03:04:05Z")!
        let end = AgendaTime(dateTime: "2026-01-02T04:04:05Z")!
        let first = AgendaOccurrence(
            eventID: "event", recurrenceID: "one", group: "home", summary: "Event",
            start: start, end: end, allDay: false
        )
        let second = AgendaOccurrence(
            eventID: "event", recurrenceID: "two", group: "home", summary: "Event",
            start: start, end: end, allDay: false
        )
        let withoutRecurrence = AgendaOccurrence(
            eventID: "event", group: "home", summary: "Event", start: start, end: end, allDay: false
        )
        let differentStart = AgendaOccurrence(
            eventID: "event", group: "home", summary: "Event", start: end, end: end, allDay: false
        )
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.id, withoutRecurrence.id)
        XCTAssertNotEqual(withoutRecurrence.id, differentStart.id)
    }
}

final class AgendaSectionsTests: XCTestCase {
    func testCancelledOccurrencesAreDroppedAndEmptyDaysOmitted() {
        let cancelled = timedOccurrence(
            "cancelled", "2026-11-24T09:00:00+01:00", "2026-11-24T10:00:00+01:00", status: .cancelled
        )
        let confirmed = timedOccurrence(
            "confirmed", "2026-11-25T09:00:00+01:00", "2026-11-25T10:00:00+01:00"
        )
        let sections = AgendaDay.sections(
            for: [cancelled, confirmed], from: localDay(2026, 11, 24), days: 3, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [localDay(2026, 11, 25)])
        XCTAssertEqual(sections.first?.items.map(\.eventID), ["confirmed"])
    }

    func testMultiDayAllDayUsesExclusiveEndAndClipsToWindow() {
        let multi = allDayOccurrence("multi", "2026-11-23", "2026-11-26")
        let tail = allDayOccurrence("tail", "2026-11-26", "2026-11-30")
        let sections = AgendaDay.sections(
            for: [multi, tail], from: localDay(2026, 11, 24), days: 3, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [
            localDay(2026, 11, 24), localDay(2026, 11, 25), localDay(2026, 11, 26),
        ])
        XCTAssertEqual(sections.map { $0.items.map(\.eventID) }, [["multi"], ["multi"], ["tail"]])
    }

    func testTimedEventCrossingMidnightAppearsOnEachOverlappedDay() {
        let crossing = timedOccurrence(
            "crossing", "2026-11-24T23:30:00+01:00", "2026-11-25T01:00:00+01:00"
        )
        let endsAtMidnight = timedOccurrence(
            "midnight", "2026-11-25T23:00:00+01:00", "2026-11-26T00:00:00+01:00"
        )
        let sections = AgendaDay.sections(
            for: [crossing, endsAtMidnight], from: localDay(2026, 11, 24), days: 3, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [localDay(2026, 11, 24), localDay(2026, 11, 25)])
        XCTAssertEqual(sections[0].items.map(\.eventID), ["crossing"])
        XCTAssertEqual(Set(sections[1].items.map(\.eventID)), Set(["crossing", "midnight"]))
    }

    func testWarsawDSTDayUsesCalendarArithmetic() {
        let allDay = allDayOccurrence("dst", "2026-03-28", "2026-03-31")
        let crossing = timedOccurrence(
            "timed", "2026-03-28T23:30:00+01:00", "2026-03-29T03:30:00+02:00"
        )
        let sections = AgendaDay.sections(
            for: [allDay, crossing], from: localDay(2026, 3, 28), days: 3, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [
            localDay(2026, 3, 28), localDay(2026, 3, 29), localDay(2026, 3, 30),
        ])
        XCTAssertEqual(sections[0].items.map(\.eventID), ["dst", "timed"])
        XCTAssertEqual(sections[1].items.map(\.eventID), ["dst", "timed"])
        XCTAssertEqual(sections[2].day.timeIntervalSince(sections[1].day), 23 * 3_600, accuracy: 1)
    }

    func testSortingIsAllDayThenStartThenSummary() {
        let occurrences = [
            timedOccurrence("later", "2026-11-24T10:00:00+01:00", "2026-11-24T11:00:00+01:00", summary: "Beta"),
            timedOccurrence("z", "2026-11-24T09:00:00+01:00", "2026-11-24T10:00:00+01:00", summary: "Zulu"),
            allDayOccurrence("whole", "2026-11-24", "2026-11-25", summary: "Whole day"),
            timedOccurrence("a", "2026-11-24T09:00:00+01:00", "2026-11-24T10:00:00+01:00", summary: "Alpha"),
        ]
        let sections = AgendaDay.sections(
            for: occurrences, from: localDay(2026, 11, 24), days: 1, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.first?.items.map(\.summary), ["Whole day", "Alpha", "Zulu", "Beta"])
    }

    func testTimedEventsAreClippedToTheWindow() {
        let before = timedOccurrence(
            "before", "2026-11-23T23:30:00+01:00", "2026-11-24T00:30:00+01:00"
        )
        let after = timedOccurrence(
            "after", "2026-11-26T00:30:00+01:00", "2026-11-26T01:30:00+01:00"
        )
        let sections = AgendaDay.sections(
            for: [before, after], from: localDay(2026, 11, 24), days: 2, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [localDay(2026, 11, 24)])
        XCTAssertEqual(sections.first?.items.map(\.eventID), ["before"])
    }

    func testZeroLengthTimedEventAppearsOnItsStartDay() {
        let reminder = timedOccurrence("reminder", "2026-11-25T09:00:00+01:00", "2026-11-25T09:00:00+01:00")
        let outside = timedOccurrence("outside", "2026-11-23T09:00:00+01:00", "2026-11-23T09:00:00+01:00")
        let sections = AgendaDay.sections(
            for: [reminder, outside], from: localDay(2026, 11, 24), days: 3, calendar: warsawCalendar()
        )
        XCTAssertEqual(sections.map(\.day), [localDay(2026, 11, 25)])
        XCTAssertEqual(sections.first?.items.map(\.eventID), ["reminder"])
    }
}

private actor MockCalendarAPI: CalendarAPI {
    struct Call: Equatable, Sendable {
        let from: Date
        let to: Date
        let group: String?
    }

    private let result: Result<AgendaPage, CalendarError>
    private(set) var calls: [Call] = []

    init(result: Result<AgendaPage, CalendarError>) {
        self.result = result
    }

    func agenda(from: Date, to: Date, group: String?) async throws -> AgendaPage {
        calls.append(Call(from: from, to: to, group: group))
        return try result.get()
    }
}

private actor PausedCalendarAPI: CalendarAPI {
    private(set) var calls: [MockCalendarAPI.Call] = []
    private var pending: [CheckedContinuation<AgendaPage, Never>] = []

    func agenda(from: Date, to: Date, group: String?) async throws -> AgendaPage {
        calls.append(MockCalendarAPI.Call(from: from, to: to, group: group))
        return await withCheckedContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }

    func resumeNext(with page: AgendaPage) {
        pending.removeFirst().resume(returning: page)
    }
}

@MainActor
final class AgendaStoreTests: XCTestCase {
    private let fixedNow = localDay(2026, 11, 24).addingTimeInterval(12 * 3_600)

    private func store(api: any CalendarAPI) -> AgendaStore {
        AgendaStore(api: api, calendar: warsawCalendar(), now: { self.fixedNow })
    }

    func testLoadedUsesLocalTodayAndThirtyDayWindow() async {
        let occurrence = allDayOccurrence("event", "2026-11-24", "2026-11-25")
        let page = AgendaPage(enabled: true, groups: ["home", "work"], truncated: true, occurrences: [occurrence])
        let api = MockCalendarAPI(result: .success(page))
        let store = store(api: api)

        await store.load()

        let day = localDay(2026, 11, 24)
        XCTAssertEqual(store.state, .loaded(sections: [AgendaDay(day: day, items: [occurrence])], truncated: true))
        XCTAssertEqual(store.groups, ["home", "work"])
        let calls = await api.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.from, day)
        XCTAssertEqual(calls.first?.to, warsawCalendar().date(byAdding: .day, value: 30, to: day))
        XCTAssertNil(calls.first?.group)
    }

    func testDisabled() async {
        let api = MockCalendarAPI(result: .success(AgendaPage(enabled: false)))
        let store = store(api: api)
        await store.load()
        XCTAssertEqual(store.state, .disabled)
    }

    func testServiceUnavailableMapsToUnavailable() async {
        XCTAssertEqual(CalendarError.wrap(APIError.http(503)), .unavailable)
        let api = MockCalendarAPI(result: .failure(.unavailable))
        let store = store(api: api)
        await store.load()
        XCTAssertEqual(store.state, .unavailable)
    }

    func testFailureMapsMessage() async {
        let api = MockCalendarAPI(result: .failure(.failed("Could not connect")))
        let store = store(api: api)
        await store.load()
        XCTAssertEqual(store.state, .failed("Could not connect"))
    }

    func testStaleResponseIsIgnoredWhenSecondLoadOvertakesFirst() async {
        let api = PausedCalendarAPI()
        let store = store(api: api)

        let first = Task { await store.load() }
        await api.waitForCalls(1)
        let second = Task { await store.load() }
        await api.waitForCalls(2)

        await api.resumeNext(with: AgendaPage(enabled: false))
        await first.value
        XCTAssertEqual(store.state, .loading)

        await api.resumeNext(with: AgendaPage(enabled: true, groups: ["new"]))
        await second.value
        XCTAssertEqual(store.state, .loaded(sections: [], truncated: false))
        XCTAssertEqual(store.groups, ["new"])
    }

    func testRefreshKeepsTheLoadedListWhileReloading() async {
        let api = PausedCalendarAPI()
        let store = store(api: api)

        let first = Task { await store.load() }
        await api.waitForCalls(1)
        await api.resumeNext(with: AgendaPage(enabled: true))
        await first.value
        XCTAssertEqual(store.state, .loaded(sections: [], truncated: false))

        let refresh = Task { await store.refresh() }
        await api.waitForCalls(2)
        XCTAssertEqual(store.state, .loaded(sections: [], truncated: false))
        await api.resumeNext(with: AgendaPage(enabled: false))
        await refresh.value
        XCTAssertEqual(store.state, .disabled)
    }

    func testGroupSelectionIsPassedThroughLoadAndRefresh() async {
        let api = MockCalendarAPI(result: .success(AgendaPage(enabled: true)))
        let store = store(api: api)
        store.selectedGroup = "family"

        await store.load()
        await store.refresh()

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.group), ["family", "family"])
    }
}
