import Foundation
import OpenAPIRuntime

extension APIClient: CalendarAPI {
    func agenda(from: Date, to: Date, group: String?, timeZone: TimeZone) async throws -> AgendaPage {
        refresh()
        let dateFormat = Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().dateSeparator(.dash)
        let input = Operations.GetCalendarInstances.Input(query: .init(
            from: from.formatted(dateFormat), to: to.formatted(dateFormat), tz: timeZone.identifier, group: group
        ))
        do {
            switch try await client.getCalendarInstances(input) {
            case .ok(let response):
                let wire = try response.body.json
                return AgendaPage(
                    enabled: wire.enabled,
                    groups: wire.groups.map(\.id),
                    truncated: wire.truncated,
                    occurrences: wire.instances.compactMap(\.occurrence)
                )
            case .badRequest: throw APIError.http(400)
            case .serviceUnavailable: throw CalendarError.unavailable
            case .undocumented(let status, _): throw mapStatus(status)
            }
        } catch {
            if APIError.isCancellation(error) { throw CancellationError() }
            // A 503 from an intermediary can have a different body than the API schema.
            if (error as? ClientError)?.response?.status.code == 503 { throw CalendarError.unavailable }
            throw CalendarError.wrap(error)
        }
    }
}

/// Decode the page metadata strictly and recover from malformed individual instances.
struct CalendarInstancesWire: Codable, Hashable, Sendable {
    let enabled: Bool
    let groups: [Components.Schemas.CalendarGroup]
    let instances: [Components.Schemas.CalendarExpandedInstance]
    let truncated: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, groups, instances, truncated
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        groups = try values.decode([Components.Schemas.CalendarGroup].self, forKey: .groups)
        truncated = try values.decode(Bool.self, forKey: .truncated)

        var rows = try values.nestedUnkeyedContainer(forKey: .instances)
        var instances: [Components.Schemas.CalendarExpandedInstance] = []
        while !rows.isAtEnd {
            // Take the row's decoder first so the array advances even if the row fails.
            let row = try rows.superDecoder()
            if let instance = try? Components.Schemas.CalendarExpandedInstance(from: row) {
                instances.append(instance)
            }
        }
        self.instances = instances
    }
}

/// Schema override for the generated client's nullable `recurrence_id` union.
struct CalendarExpandedInstanceWire: Codable, Hashable, Sendable {
    private enum Status: String, Codable, Sendable {
        case confirmed, tentative
    }

    private let instanceId: String
    private let eventId: String
    private let revision: Int
    private let group: String
    private let summary: String
    private let location: String
    private let start: CalendarWireTime
    private let end: CalendarWireTime
    private let allDay: Bool
    private let status: Status
    private let recurrenceId: CalendarWireTime

    private enum CodingKeys: String, CodingKey {
        case instanceId = "instance_id"
        case eventId = "event_id"
        case revision, group, summary, location, start, end
        case allDay = "all_day"
        case status
        case recurrenceId = "recurrence_id"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try values.decode(String.self, forKey: .instanceId)
        eventId = try values.decode(String.self, forKey: .eventId)
        revision = try values.decode(Int.self, forKey: .revision)
        group = try values.decode(String.self, forKey: .group)
        summary = try values.decode(String.self, forKey: .summary)
        location = try values.decode(String.self, forKey: .location)
        start = try values.decode(CalendarWireTime.self, forKey: .start)
        end = try values.decode(CalendarWireTime.self, forKey: .end)
        if start == .null || end == .null {
            let key: CodingKeys = start == .null ? .start : .end
            throw DecodingError.valueNotFound(
                CalendarWireTime.self,
                .init(codingPath: values.codingPath + [key], debugDescription: "Expected a calendar date or time")
            )
        }
        allDay = try values.decode(Bool.self, forKey: .allDay)
        status = try values.decode(Status.self, forKey: .status)
        recurrenceId = try values.decode(CalendarWireTime.self, forKey: .recurrenceId)
    }

    var occurrence: AgendaOccurrence? {
        guard let start = start.agendaTime, let end = end.agendaTime,
              recurrenceId == .null || recurrenceId.agendaTime != nil else { return nil }
        return AgendaOccurrence(
            id: instanceId, eventID: eventId, recurrenceID: recurrenceId.rawValue,
            group: group, summary: summary, location: location, start: start, end: end,
            allDay: allDay, status: status == .confirmed ? .confirmed : .tentative
        )
    }
}

private enum CalendarWireTime: Codable, Hashable, Sendable {
    case date(Components.Schemas.CalendarDate)
    case dateTime(Components.Schemas.CalendarDateTime)
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let date = try? value.decode(Components.Schemas.CalendarDate.self) {
            self = .date(date)
        } else {
            self = .dateTime(try value.decode(Components.Schemas.CalendarDateTime.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .date(let date): try value.encode(date)
        case .dateTime(let dateTime): try value.encode(dateTime)
        case .null: try value.encodeNil()
        }
    }

    var agendaTime: AgendaTime? {
        switch self {
        case .date(let date): AgendaTime(date: date.date)
        case .dateTime(let time): AgendaTime(dateTime: time.dateTime, timeZone: time.timeZone)
        case .null: nil
        }
    }

    var rawValue: String? {
        switch self {
        case .date(let date): date.date
        case .dateTime(let time): time.dateTime
        case .null: nil
        }
    }
}
