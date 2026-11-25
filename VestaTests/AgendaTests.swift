import Foundation
import HTTPTypes
import XCTest
@testable import Vesta

private func warsawCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return calendar
}

private func santiagoCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Santiago")!
    return calendar
}

private func localDay(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = warsawCalendar()) -> Date {
    calendar.startOfDay(for: calendar.date(from: DateComponents(year: year, month: month, day: day))!)
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
        XCTAssertNil(AgendaTime(dateTime: "2026-01-02T03:04:05+02:60", timeZone: "Europe/Warsaw"))
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

    func testTimeRangeUsesTheProvidedLocale() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .hour, value: 1, to: start))
        let occurrence = AgendaOccurrence(
            eventID: "event", group: "home", summary: "Event", start: .instant(start), end: .instant(end), allDay: false
        )

        let polish = try XCTUnwrap(occurrence.timeRange(locale: Locale(identifier: "pl_PL")))
        let english = try XCTUnwrap(occurrence.timeRange(locale: Locale(identifier: "en_US")))

        XCTAssertTrue(polish.contains("15:00"))
        XCTAssertTrue(polish.contains("16:00"))
        XCTAssertTrue(english.contains("3:00"))
        XCTAssertTrue(english.contains("4:00"))
        XCTAssertTrue(english.contains("PM"))
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

    func testMidnightSpringForwardProducesOneSectionPerLocalDay() {
        let calendar = santiagoCalendar()
        let multiDay = allDayOccurrence("multi", "2026-09-05", "2026-09-08")
        let followingDay = allDayOccurrence("following", "2026-09-07", "2026-09-08")
        let sept5 = localDay(2026, 9, 5, calendar: calendar)
        let sept6 = localDay(2026, 9, 6, calendar: calendar)
        let sept7 = localDay(2026, 9, 7, calendar: calendar)

        let sections = AgendaDay.sections(for: [multiDay, followingDay], from: sept5, days: 4, calendar: calendar)

        XCTAssertEqual(calendar.component(.hour, from: sept6), 1)
        XCTAssertEqual(calendar.component(.hour, from: sept7), 0)
        XCTAssertEqual(sections.map(\.day), [sept5, sept6, sept7])
        XCTAssertEqual(sections.map { Set($0.items.map(\.eventID)) }, [["multi"], ["multi"], ["multi", "following"]])
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
        let timeZone: TimeZone
    }

    private let result: Result<AgendaPage, CalendarError>
    private(set) var calls: [Call] = []

    init(result: Result<AgendaPage, CalendarError>) {
        self.result = result
    }

    func agenda(from: Date, to: Date, group: String?, timeZone: TimeZone) async throws -> AgendaPage {
        calls.append(Call(from: from, to: to, group: group, timeZone: timeZone))
        return try result.get()
    }
}

private actor PausedCalendarAPI: CalendarAPI {
    private(set) var calls: [MockCalendarAPI.Call] = []
    private var pending: [CheckedContinuation<AgendaPage, any Error>] = []

    func agenda(from: Date, to: Date, group: String?, timeZone: TimeZone) async throws -> AgendaPage {
        calls.append(MockCalendarAPI.Call(from: from, to: to, group: group, timeZone: timeZone))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func waitForCalls(_ count: Int) async {
        while calls.count < count { await Task.yield() }
    }

    func resumeNext(with page: AgendaPage) {
        pending.removeFirst().resume(returning: page)
    }

    func resumeLatest(with page: AgendaPage) {
        pending.removeLast().resume(returning: page)
    }

    func failNext(with error: CalendarError) {
        pending.removeFirst().resume(throwing: error)
    }

    func cancelNext() {
        pending.removeFirst().resume(throwing: CancellationError())
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
        XCTAssertEqual(calls.first?.timeZone, warsawCalendar().timeZone)
        XCTAssertNil(calls.first?.group)
    }

    func testMidnightSpringForwardUsesAnExclusiveLocalDayThirty() async {
        let calendar = santiagoCalendar()
        let from = localDay(2026, 9, 6, calendar: calendar)
        let to = localDay(2026, 10, 6, calendar: calendar)
        let inside = allDayOccurrence("inside", "2026-10-05", "2026-10-06")
        let outside = timedOccurrence("outside", "2026-10-06T00:30:00-03:00", "2026-10-06T01:30:00-03:00")
        let api = MockCalendarAPI(result: .success(AgendaPage(enabled: true, occurrences: [inside, outside])))
        let store = AgendaStore(api: api, calendar: calendar, now: { from.addingTimeInterval(12 * 3_600) })

        await store.load()

        let calls = await api.calls
        XCTAssertEqual(calls, [.init(from: from, to: to, group: nil, timeZone: calendar.timeZone)])
        XCTAssertEqual(calendar.component(.hour, from: from), 1)
        XCTAssertEqual(calendar.component(.hour, from: to), 0)
        let sections = [AgendaDay(day: localDay(2026, 10, 5, calendar: calendar), items: [inside])]
        XCTAssertEqual(store.state, .loaded(sections: sections, truncated: false))
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

    func testCancelledRefreshKeepsThePreviousLoadedState() async {
        let api = PausedCalendarAPI()
        let store = store(api: api)
        let day = localDay(2026, 11, 24)
        let occurrence = allDayOccurrence("event", "2026-11-24", "2026-11-25")
        let first = Task { await store.load() }
        await api.waitForCalls(1)
        await api.resumeNext(with: AgendaPage(enabled: true, groups: ["home"], truncated: true, occurrences: [occurrence]))
        await first.value
        let loaded = AgendaStore.State.loaded(sections: [AgendaDay(day: day, items: [occurrence])], truncated: true)

        let refresh = Task { await store.refresh() }
        await api.waitForCalls(2)
        await api.cancelNext()
        await refresh.value

        XCTAssertEqual(store.state, loaded)
        XCTAssertEqual(store.groups, ["home"])

        let cancelledTask = Task { await store.refresh() }
        await api.waitForCalls(3)
        cancelledTask.cancel()
        await api.failNext(with: .unavailable)
        await cancelledTask.value

        XCTAssertEqual(store.state, loaded)
        XCTAssertEqual(store.groups, ["home"])
    }

    func testGroupSelectionIsPassedThroughLoadAndRefresh() async {
        let api = MockCalendarAPI(result: .success(AgendaPage(enabled: true, groups: ["home", "family"])))
        let store = store(api: api)
        store.selectedGroup = "family"

        await store.load()
        await store.refresh()

        let calls = await api.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.group), ["family", "family"])
    }

    func testMissingGroupResetsSelectionToDefault() async {
        let api = MockCalendarAPI(result: .success(AgendaPage(enabled: true, groups: ["home", "work"])))
        let store = store(api: api)
        store.selectedGroup = "removed"

        await store.load()

        XCTAssertNil(store.selectedGroup)
        XCTAssertEqual(store.groups, ["home", "work"])
        let initialCalls = await api.calls
        XCTAssertEqual(initialCalls.first?.group, "removed")
        XCTAssertLessThanOrEqual(initialCalls.count, 2)

        await store.refresh()

        let lastCall = await api.calls.last
        XCTAssertNil(lastCall?.group)
        XCTAssertNil(store.selectedGroup)
    }
}

@MainActor
final class CalendarClientTests: XCTestCase {
    private static let instancesJSON = """
    {
      "enabled": true,
      "groups": [{"id": "shared home"}, {"id": "work"}],
      "instances": [
        {
          "instance_id": "day",
          "event_id": "day",
          "revision": 1,
          "group": "shared home",
          "summary": "All-day event",
          "location": "",
          "start": {"date": "2026-11-24"},
          "end": {"date": "2026-11-25"},
          "all_day": true,
          "status": "confirmed",
          "recurrence_id": null
        },
        {
          "instance_id": "series/2026-11-25T08:00:00Z",
          "event_id": "series",
          "revision": 2,
          "group": "shared home",
          "summary": "Moved occurrence",
          "location": "Meeting room",
          "start": {"dateTime": "2026-11-25T11:00:00+01:00"},
          "end": {"dateTime": "2026-11-25T12:00:00+01:00"},
          "all_day": false,
          "status": "tentative",
          "recurrence_id": {"dateTime": "2026-11-25T08:00:00Z"}
        },
        {
          "instance_id": "local",
          "event_id": "local",
          "revision": 1,
          "group": "shared home",
          "summary": "Named time zone",
          "location": "",
          "start": {"dateTime": "2026-11-26T11:00:00", "timeZone": "Europe/Warsaw"},
          "end": {"dateTime": "2026-11-26T12:00:00", "timeZone": "Europe/Warsaw"},
          "all_day": false,
          "status": "confirmed",
          "recurrence_id": null
        },
        {
          "instance_id": "invalid",
          "event_id": "invalid",
          "revision": 1,
          "group": "shared home",
          "summary": "Invalid time",
          "location": "",
          "start": {"date": "2026-11-27"},
          "end": {"date": "2026-11-31"},
          "all_day": true,
          "status": "confirmed",
          "recurrence_id": null
        }
      ],
      "truncated": true
    }
    """

    private func agenda(_ api: APIClient, group: String? = nil) async throws -> AgendaPage {
        try await api.agenda(
            from: localDay(2026, 11, 24), to: localDay(2026, 12, 24),
            group: group, timeZone: warsawCalendar().timeZone
        )
    }

    func testWireRequestUsesLocalDatesTimeZoneGroupAndSessionBearer() async throws {
        let transport = CapturingTransport(status: 200, body: Self.instancesJSON)
        let sessionCredential = UUID().uuidString
        let pairing = ReceiptPairing(store: MemoryDeviceTokenStore(.init(
            server: AppConfig.serverURL, credential: fakeDeviceToken
        )))
        let api = APIClient(transport: transport, receiptPairing: pairing, sessionToken: { sessionCredential })

        _ = try await agenda(api, group: "shared home")

        let request = try XCTUnwrap(transport.last?.request)
        let components = try XCTUnwrap(URLComponents(string: request.path ?? ""))
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(components.path, "/api/calendars/instances")
        XCTAssertEqual(Set(components.queryItems ?? []), [
            URLQueryItem(name: "from", value: "2026-11-24"),
            URLQueryItem(name: "to", value: "2026-12-24"),
            URLQueryItem(name: "tz", value: "Europe/Warsaw"),
            URLQueryItem(name: "group", value: "shared home"),
        ])
        XCTAssertEqual(request.headerFields[.authorization], "Bearer \(sessionCredential)")
    }

    func testDecodesInstancesAndSkipsAnInvalidTime() async throws {
        let transport = CapturingTransport(status: 200, body: Self.instancesJSON)
        let page = try await agenda(APIClient(transport: transport, sessionToken: { nil }))

        XCTAssertTrue(page.enabled)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.groups, ["shared home", "work"])
        XCTAssertEqual(page.occurrences.map(\.id), ["day", "series/2026-11-25T08:00:00Z", "local"])
        let allDay = try XCTUnwrap(page.occurrences.first(where: { $0.id == "day" }))
        XCTAssertEqual(allDay.start, .allDay(year: 2026, month: 11, day: 24))
        XCTAssertEqual(allDay.end, .allDay(year: 2026, month: 11, day: 25))
        XCTAssertTrue(allDay.allDay)
        XCTAssertNil(allDay.recurrenceID)

        let moved = try XCTUnwrap(page.occurrences.first(where: { $0.eventID == "series" }))
        XCTAssertEqual(moved.recurrenceID, "2026-11-25T08:00:00Z")
        XCTAssertEqual(moved.start, AgendaTime(dateTime: "2026-11-25T10:00:00Z"))
        XCTAssertEqual(moved.end, AgendaTime(dateTime: "2026-11-25T11:00:00Z"))
        XCTAssertFalse(moved.allDay)
        XCTAssertEqual(moved.status, .tentative)
        XCTAssertEqual(moved.location, "Meeting room")
        XCTAssertEqual(moved.summary, "Moved occurrence")

        let local = try XCTUnwrap(page.occurrences.first(where: { $0.id == "local" }))
        XCTAssertEqual(local.start, AgendaTime(dateTime: "2026-11-26T10:00:00Z"))
        XCTAssertEqual(local.end, AgendaTime(dateTime: "2026-11-26T11:00:00Z"))
    }

    func testMalformedInstancesFailStrictDecodeAndAreSkippedInThePage() async throws {
        let original = Data(Self.instancesJSON.utf8)
        var pageJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        let valid = try XCTUnwrap(pageJSON["instances"] as? [[String: Any]])
        let allDay = try XCTUnwrap(valid.first)
        let malformedFields: [(key: String, value: Any?)] = [
            ("start", nil),
            ("end", "2026-11-25"),
            ("start", NSNull()),
            ("recurrence_id", nil),
        ]
        var malformed: [[String: Any]] = []
        for (index, field) in malformedFields.enumerated() {
            var row = allDay
            row["instance_id"] = "malformed-\(index)"
            row[field.key] = field.value
            let data = try JSONSerialization.data(withJSONObject: row)
            XCTAssertThrowsError(try JSONDecoder().decode(CalendarExpandedInstanceWire.self, from: data)) {
                XCTAssertTrue($0 is DecodingError)
            }
            malformed.append(row)
        }

        pageJSON["instances"] = [allDay] + malformed + Array(valid.dropFirst())
        let data = try JSONSerialization.data(withJSONObject: pageJSON)
        let transport = CapturingTransport(status: 200, body: String(decoding: data, as: UTF8.self))
        let page = try await agenda(APIClient(transport: transport, sessionToken: { nil }))

        XCTAssertEqual(page.occurrences.map(\.id), ["day", "series/2026-11-25T08:00:00Z", "local"])
        XCTAssertNil(page.occurrences.first?.recurrenceID)
    }

    func testDecodesDisabledFeedAndOmitsGroupByDefault() async throws {
        let transport = CapturingTransport(status: 200, body: """
        {"enabled": false, "groups": [], "instances": [], "truncated": false}
        """)
        let page = try await agenda(APIClient(transport: transport, sessionToken: { nil }))

        XCTAssertEqual(page, AgendaPage(enabled: false))
        let components = try XCTUnwrap(URLComponents(string: transport.last?.request.path ?? ""))
        XCTAssertFalse(components.queryItems?.contains(where: { $0.name == "group" }) ?? true)
    }

    func testForbiddenResponseWithEmptyBodyMapsToForbidden() async {
        let api = APIClient(transport: StubTransport { _ in (403, nil) }, sessionToken: { nil })
        do {
            _ = try await agenda(api)
            XCTFail("Expected forbidden")
        } catch {
            XCTAssertEqual(error as? CalendarError, .forbidden)
        }
    }

    func testUnauthorizedResponseWithEmptyBodyMapsToUnauthorized() async {
        XCTAssertEqual(CalendarError.wrap(APIError.unauthorized), .unauthorized)
        XCTAssertEqual(CalendarError.wrap(APIError.http(401)), .unauthorized)
        let api = APIClient(transport: StubTransport { _ in (401, nil) }, sessionToken: { nil })
        do {
            _ = try await agenda(api)
            XCTFail("Expected unauthorized")
        } catch {
            XCTAssertEqual(error as? CalendarError, .unauthorized)
        }
    }

    func testCancelledTransportThrowsCancellationError() async {
        let failures: [any Error] = [CancellationError(), URLError(.cancelled)]
        for failure in failures {
            let api = APIClient(transport: StubTransport { _ in throw failure }, sessionToken: { nil })
            do {
                _ = try await agenda(api)
                XCTFail("Expected cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }
    }

    func testServiceUnavailableResponseMapsToUnavailable() async {
        let transport = CapturingTransport(status: 503, body: #"{"error": "invalid_calendar_configuration"}"#)
        let api = APIClient(transport: transport, sessionToken: { nil })
        do {
            _ = try await agenda(api)
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? CalendarError, .unavailable)
        }
    }
}

extension MockHestiaAPI: CalendarAPI {
    func agenda(from: Date, to: Date, group: String?, timeZone: TimeZone) async throws -> AgendaPage {
        guard let calendarStub else { return AgendaPage(enabled: true) }
        return try await calendarStub.agenda(from: from, to: to, group: group, timeZone: timeZone)
    }
}

@MainActor
final class CalendarAccessTests: XCTestCase {
    private let grant = Capabilities(installation: [.calendarView])

    private func makeApp(_ mock: MockHestiaAPI) -> AppState {
        AppState(
            api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            events: { AsyncStream { $0.finish() } }
        )
    }

    func testCalendarAPIIsHiddenOnLegacyServerWithCalendarViewGrant() async {
        let mock = MockHestiaAPI()
        await mock.setCapabilities(grant)
        let app = makeApp(mock)
        await app.connect()

        XCTAssertTrue(grant.canViewCalendar)
        XCTAssertNil(app.calendarAPI)
        XCTAssertNil(app.makeAgendaStore())
    }

    func testCalendarAPIRequiresViewGrantWhenFeatureIsEnabled() async {
        let mock = MockHestiaAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        let app = makeApp(mock)
        XCTAssertNil(app.calendarAPI)
        await mock.setCapabilities(Capabilities(installation: [.calendarEdit]))
        await app.connect()
        XCTAssertNil(app.calendarAPI)

        await mock.setCapabilities(grant)
        await app.refresh()
        XCTAssertNotNil(app.calendarAPI)
        XCTAssertNotNil(app.makeAgendaStore())
        XCTAssertTrue(Capabilities(isAuthOff: true).canViewCalendar)
    }

    func testForbiddenClearsStoreAndRefreshesCapabilitiesOnce() async throws {
        let mock = MockHestiaAPI()
        let calendar = PausedCalendarAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(calendar)
        let app = makeApp(mock)
        await app.connect()

        let store = try XCTUnwrap(app.makeAgendaStore())
        let firstLoad = Task { await store.load() }
        await calendar.waitForCalls(1)
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["home"]))
        await firstLoad.value
        XCTAssertEqual(store.groups, ["home"])
        store.selectedGroup = "home"

        let updated = Capabilities(installation: [.calendarView, .calendarEdit])
        await mock.setCapabilities(updated)
        let refresh = Task { await store.refresh() }
        await calendar.waitForCalls(2)
        await calendar.failNext(with: .forbidden)
        await refresh.value

        XCTAssertTrue(store.isDiscarded)
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedGroup)
        await store.load()
        await store.refresh()
        try await waitUntil("the Calendar denial's capability refresh") { app.capabilities == updated }
        let calendarCalls = await calendar.calls.count
        let sessionCalls = await mock.calls
        XCTAssertEqual(calendarCalls, 2)
        XCTAssertEqual(sessionCalls, [.capabilities, .capabilities])
        XCTAssertEqual(app.phase, .ready)
    }

    func testStaleForbiddenAfterGroupSwitchDoesNotDiscardOrRefreshCapabilities() async throws {
        let mock = MockHestiaAPI()
        let calendar = PausedCalendarAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(calendar)
        let app = makeApp(mock)
        await app.connect()

        let store = try XCTUnwrap(app.makeAgendaStore())
        let first = Task { await store.load() }
        await calendar.waitForCalls(1)

        store.selectedGroup = "work"
        let second = Task { await store.load() }
        await calendar.waitForCalls(2)
        await calendar.resumeLatest(with: AgendaPage(enabled: true, groups: ["home", "work"], truncated: true))
        await second.value

        await calendar.failNext(with: .forbidden)
        await first.value

        XCTAssertEqual(store.state, .loaded(sections: [], truncated: true))
        XCTAssertFalse(store.isDiscarded)
        XCTAssertEqual(store.selectedGroup, "work")
        XCTAssertEqual(store.groups, ["home", "work"])
        let calendarCalls = await calendar.calls
        XCTAssertEqual(calendarCalls.map(\.group), [nil, "work"])
        let sessionCalls = await mock.calls
        XCTAssertEqual(sessionCalls, [.capabilities])
        XCTAssertEqual(app.phase, .ready)
    }

    func testUnauthorizedDiscardsTheAgendaAndInvalidatesTheSession() async throws {
        let mock = MockHestiaAPI()
        let calendar = PausedCalendarAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(calendar)
        let app = makeApp(mock)
        await app.connect()

        let store = try XCTUnwrap(app.makeAgendaStore())
        let first = Task { await store.load() }
        await calendar.waitForCalls(1)
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["home", "work"]))
        await first.value
        XCTAssertEqual(store.groups, ["home", "work"])
        store.selectedGroup = "work"

        let refresh = Task { await store.refresh() }
        await calendar.waitForCalls(2)
        await calendar.failNext(with: .unauthorized)
        await refresh.value

        XCTAssertEqual(app.phase, .needsAuth)
        XCTAssertNil(app.capabilities)
        XCTAssertNil(app.calendarAPI)
        XCTAssertNil(app.makeAgendaStore())
        XCTAssertTrue(store.isDiscarded)
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.selectedGroup)
        try await waitUntil("Calendar session invalidation") { await mock.count(.logout) == 1 }
        let sessionCalls = await mock.calls
        XCTAssertEqual(sessionCalls, [.capabilities, .logout])
    }

    func testClosingAgendaDiscardsALateResponse() async throws {
        let mock = MockHestiaAPI()
        let calendar = PausedCalendarAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(calendar)
        let app = makeApp(mock)
        await app.connect()

        let store = try XCTUnwrap(app.makeAgendaStore())
        let load = Task { await store.load() }
        await calendar.waitForCalls(1)
        app.closeAgenda()
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["late"], truncated: true))
        await load.value

        XCTAssertTrue(store.isDiscarded)
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.groups.isEmpty)
    }

    func testStoreIsDiscardedWhenFeatureOrPermissionIsWithdrawn() async throws {
        let mock = MockHestiaAPI()
        let calendar = PausedCalendarAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(calendar)
        let app = makeApp(mock)
        await app.connect()

        let featureStore = try XCTUnwrap(app.makeAgendaStore())
        let initialLoad = Task { await featureStore.load() }
        await calendar.waitForCalls(1)
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["home"]))
        await initialLoad.value
        XCTAssertEqual(featureStore.groups, ["home"])

        let lateLoad = Task { await featureStore.refresh() }
        await calendar.waitForCalls(2)
        await mock.setFeatures([.capabilities])
        await app.refresh()
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["late"]))
        await lateLoad.value
        XCTAssertTrue(featureStore.isDiscarded)
        XCTAssertEqual(featureStore.state, .idle)
        XCTAssertTrue(featureStore.groups.isEmpty)
        XCTAssertNil(app.calendarAPI)
        XCTAssertEqual(app.capabilities, grant)

        await mock.setFeatures([.capabilities, .calendarInstances])
        await app.refresh()
        let permissionStore = try XCTUnwrap(app.makeAgendaStore())
        let permissionLoad = Task { await permissionStore.load() }
        await calendar.waitForCalls(3)
        await calendar.resumeNext(with: AgendaPage(enabled: true, groups: ["home"]))
        await permissionLoad.value
        XCTAssertEqual(permissionStore.groups, ["home"])
        await mock.setCapabilities(Capabilities())
        await app.refresh()
        XCTAssertTrue(permissionStore.isDiscarded)
        XCTAssertTrue(permissionStore.groups.isEmpty)
        XCTAssertNil(app.calendarAPI)
    }

    func testSigningOutDiscardsAgenda() async throws {
        let mock = MockHestiaAPI()
        await mock.setFeatures([.capabilities, .calendarInstances])
        await mock.setCapabilities(grant)
        await mock.setCalendarStub(MockCalendarAPI(result: .success(AgendaPage(enabled: true, groups: ["home"]))))
        let app = makeApp(mock)
        await app.connect()

        let store = try XCTUnwrap(app.makeAgendaStore())
        await store.load()
        XCTAssertEqual(store.groups, ["home"])
        await app.signOut()

        XCTAssertTrue(store.isDiscarded)
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(app.calendarAPI)
    }
}
