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
        } catch let error as ClientError where error.response?.status.code == 503 {
            // A 503 from an intermediary can have a different body than the API schema.
            throw CalendarError.unavailable
        } catch {
            throw CalendarError.wrap(error)
        }
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
    private let start: CalendarWireTime?
    private let end: CalendarWireTime?
    private let allDay: Bool
    private let status: Status
    private let recurrenceId: CalendarWireTime?

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
        guard values.contains(.recurrenceId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.recurrenceId,
                .init(codingPath: values.codingPath, debugDescription: "Missing required recurrence_id")
            )
        }
        instanceId = try values.decode(String.self, forKey: .instanceId)
        eventId = try values.decode(String.self, forKey: .eventId)
        revision = try values.decode(Int.self, forKey: .revision)
        group = try values.decode(String.self, forKey: .group)
        summary = try values.decode(String.self, forKey: .summary)
        location = try values.decode(String.self, forKey: .location)
        start = try? values.decode(CalendarWireTime.self, forKey: .start)
        end = try? values.decode(CalendarWireTime.self, forKey: .end)
        allDay = try values.decode(Bool.self, forKey: .allDay)
        status = try values.decode(Status.self, forKey: .status)
        recurrenceId = try? values.decode(CalendarWireTime.self, forKey: .recurrenceId)
    }

    var occurrence: AgendaOccurrence? {
        guard let start = start?.agendaTime, let end = end?.agendaTime, let recurrenceId,
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
