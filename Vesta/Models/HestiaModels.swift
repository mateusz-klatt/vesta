import Foundation

// Domain types are the generated OpenAPI schemas (from Vesta/openapi.json).
// These thin aliases + grouping helpers keep the views readable.

typealias Device = Components.Schemas.DeviceInfo
typealias Globals = Components.Schemas.Globals
typealias Summary = Components.Schemas.Summary

/// A device addressed for the UI (the discovery map is keyed by node id).
struct IdentifiedDevice: Identifiable, Sendable {
    let id: String
    let device: Device

    // A resource's locale selects the translation language. String's direct
    // locale argument only controls formatting, ignoring the in-app picker.
    func displayName(locale: Locale) -> String {
        device.name ?? String(localized: LocalizedStringResource("Node \(id)", locale: locale))
    }
}

/// Devices grouped by their registry room, for the Rooms view.
struct RoomGroup: Identifiable, Sendable {
    let id: String          // room name (or "" for unassigned)
    var devices: [IdentifiedDevice]
    var name: String { name(locale: .current) }

    func name(locale: Locale) -> String {
        id.isEmpty ? String(localized: LocalizedStringResource("No room", locale: locale)) : id
    }

    static func group(_ discovery: Components.Schemas.Discovery) -> [RoomGroup] {
        let items = discovery.devices.additionalProperties
            .map { IdentifiedDevice(id: $0.key, device: $0.value) }
            .sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        let byRoom = Dictionary(grouping: items) { $0.device.room ?? "" }
        return byRoom
            .map { RoomGroup(id: $0.key, devices: $0.value) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
