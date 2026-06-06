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

    var displayName: String { device.name ?? String(localized: "Node \(id)") }
}

/// Devices grouped by their registry room, for the Rooms view.
struct RoomGroup: Identifiable, Sendable {
    let id: String          // room name (or "" for unassigned)
    var devices: [IdentifiedDevice]
    var name: String { id.isEmpty ? String(localized: "No room") : id }

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
