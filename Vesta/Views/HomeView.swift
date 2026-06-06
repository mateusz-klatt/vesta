import SwiftUI

/// Rooms home: live environment header + devices grouped by room, with inline
/// on/off control for switchable devices. Pull to refresh; live SSE events also
/// refresh in the background.
struct HomeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let globals = app.globals {
                        GlobalsHeader(globals: globals)
                    }
                    ForEach(app.rooms) { room in
                        RoomCard(room: room)
                    }
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle("Rooms")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let user = app.whoami?.user {
                        Text(user).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .refreshable { await app.loadDiscovery() }
        }
    }
}

private struct GlobalsHeader: View {
    let globals: Globals

    var body: some View {
        HStack(spacing: 20) {
            if let crib = globals.cribTemp {
                Label("\(crib, specifier: "%.1f")°", systemImage: "thermometer.medium")
            }
            if let out = globals.outdoorTemp {
                Label("\(out, specifier: "%.1f")°", systemImage: "cloud.sun")
            }
            if let hum = globals.outdoorHumidity {
                Text(verbatim: "\(Int(hum))%").foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textPrimary)
        .vestaCard()
    }
}

private struct RoomCard: View {
    let room: RoomGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(room.name)
                .font(.headline)
            ForEach(room.devices) { item in
                DeviceRow(item: item)
                if item.id != room.devices.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vestaCard()
    }
}

private struct DeviceRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .foregroundStyle(Theme.textPrimary)
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if item.device._switch != nil {
                Toggle("", isOn: Binding(
                    get: { item.device._switch ?? false },
                    set: { newValue in Task { await app.toggle(item, on: newValue) } }
                ))
                .labelsHidden()
            }
        }
    }

    private var stateText: String {
        let device = item.device
        if let on = device._switch { return on ? String(localized: "on") : String(localized: "off") }
        if let door = device.door { return door }
        if let motion = device.motion { return motion ? String(localized: "motion") : String(localized: "no motion") }
        if device._type == "thermostat", let setpoint = device.setpoint {
            return String(localized: "setpoint \(Int(setpoint))°")
        }
        if let temperature = device.temperature { return String(format: "%.1f°", temperature) }
        return device._type
    }
}
