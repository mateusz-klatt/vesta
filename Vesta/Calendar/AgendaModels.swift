import Foundation

enum AgendaTime: Hashable, Sendable {
    case allDay(year: Int, month: Int, day: Int)
    case instant(Date)

    init?(date: String) {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard date.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil, parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard components.isValidDate(in: calendar) else { return nil }
        self = .allDay(year: parts[0], month: parts[1], day: parts[2])
    }

    init?(dateTime: String, timeZone: String? = nil) {
        let pattern = /([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(?:([Zz])|([+-])([0-9]{2}):([0-9]{2}))?/
        guard let match = dateTime.wholeMatch(of: pattern),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
              hour < 24, minute < 60, second < 60 else { return nil }

        let zone: TimeZone
        if match.8 != nil {
            guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
            zone = utc
        } else if let sign = match.9 {
            guard let offsetHour = match.10, let offsetMinute = match.11,
                  let hours = Int(offsetHour), let minutes = Int(offsetMinute), hours < 24, minutes < 60
            else { return nil }
            let offset = hours * 3_600 + minutes * 60
            guard let parsed = TimeZone(secondsFromGMT: sign == "-" ? -offset : offset) else { return nil }
            zone = parsed
        } else {
            guard let timeZone, let parsed = TimeZone(identifier: timeZone) else { return nil }
            zone = parsed
        }

        var nanosecond = 0
        if let fraction = match.7 {
            let digits = String((String(fraction) + "000000000").prefix(9))
            guard let parsed = Int(digits) else { return nil }
            nanosecond = parsed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        )
        guard components.isValidDate(in: calendar), let localDate = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: localDate)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day,
              roundTrip.hour == hour, roundTrip.minute == minute, roundTrip.second == second else { return nil }
        self = .instant(localDate.addingTimeInterval(Double(nanosecond) / 1_000_000_000))
    }

    fileprivate var stableIdentifier: String {
        switch self {
        case let .allDay(year, month, day): String(format: "%04d-%02d-%02d", year, month, day)
        case let .instant(date): String(date.timeIntervalSince1970)
        }
    }

    fileprivate func day(calendar: Calendar) -> Date? {
        switch self {
        case let .allDay(year, month, day):
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            guard let date = gregorian.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
            return calendar.startOfDay(for: date)
        case let .instant(date):
            return calendar.startOfDay(for: date)
        }
    }

    fileprivate func sortDate(calendar: Calendar) -> Date? {
        if case let .instant(date) = self { return date }
        return day(calendar: calendar)
    }
}

struct AgendaOccurrence: Identifiable, Hashable, Sendable {
    enum Status: String, Hashable, Sendable {
        case confirmed, tentative, cancelled
    }

    let id: String
    let eventID: String
    let recurrenceID: String?
    let group: String
    let summary: String
    let location: String?
    let start: AgendaTime
    let end: AgendaTime
    let allDay: Bool
    let status: Status

    init(id: String? = nil, eventID: String, recurrenceID: String? = nil, group: String, summary: String,
         location: String? = nil, start: AgendaTime, end: AgendaTime, allDay: Bool,
         status: Status = .confirmed) {
        self.id = id ?? (eventID + "\u{1F}" + (recurrenceID ?? start.stableIdentifier))
        self.eventID = eventID
        self.recurrenceID = recurrenceID
        self.group = group
        self.summary = summary
        self.location = location
        self.start = start
        self.end = end
        self.allDay = allDay
        self.status = status
    }
}

struct AgendaPage: Hashable, Sendable {
    let enabled: Bool
    let groups: [String]
    let truncated: Bool
    let occurrences: [AgendaOccurrence]

    init(enabled: Bool, groups: [String] = [], truncated: Bool = false, occurrences: [AgendaOccurrence] = []) {
        self.enabled = enabled
        self.groups = groups
        self.truncated = truncated
        self.occurrences = occurrences
    }
}

struct AgendaDay: Identifiable, Hashable, Sendable {
    let day: Date
    let items: [AgendaOccurrence]

    var id: Date { day }

    static func sections(for occurrences: [AgendaOccurrence], from: Date, days: Int,
                         calendar: Calendar) -> [AgendaDay] {
        let windowStart = calendar.startOfDay(for: from)
        guard days > 0, let end = calendar.date(byAdding: .day, value: days, to: windowStart) else { return [] }
        // Day arithmetic can carry forward a 01:00 start when local midnight is skipped.
        let windowEnd = calendar.startOfDay(for: end)
        var itemsByDay: [Date: [AgendaOccurrence]] = [:]

        func add(_ occurrence: AgendaOccurrence, start: Date, end: Date) {
            // A zero-length (or inverted) event still happens at its start, e.g. a
            // reminder or an event whose end is unspecified.
            if end <= start {
                guard start >= windowStart, start < windowEnd else { return }
                itemsByDay[calendar.startOfDay(for: start), default: []].append(occurrence)
                return
            }
            let clippedStart = max(start, windowStart)
            let clippedEnd = min(end, windowEnd)
            guard clippedStart < clippedEnd else { return }
            var day = calendar.startOfDay(for: clippedStart)
            while day < clippedEnd {
                itemsByDay[day, default: []].append(occurrence)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = calendar.startOfDay(for: next)
            }
        }

        for occurrence in occurrences where occurrence.status != .cancelled {
            if occurrence.allDay {
                guard let start = occurrence.start.day(calendar: calendar),
                      let end = occurrence.end.day(calendar: calendar) else { continue }
                add(occurrence, start: start, end: end)
            } else if case let .instant(start) = occurrence.start, case let .instant(end) = occurrence.end {
                add(occurrence, start: start, end: end)
            }
        }

        return itemsByDay.keys.sorted().map { day in
            let items = itemsByDay[day, default: []].sorted { lhs, rhs in
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                guard let lhsSortDate = lhs.start.sortDate(calendar: calendar),
                      let rhsSortDate = rhs.start.sortDate(calendar: calendar) else { return lhs.id < rhs.id }
                if lhsSortDate != rhsSortDate { return lhsSortDate < rhsSortDate }
                if lhs.summary != rhs.summary { return lhs.summary < rhs.summary }
                return lhs.id < rhs.id
            }
            return AgendaDay(day: day, items: items)
        }
    }
}
