import SwiftUI

/// Rooms home — the wife-friendly surface: live environment, A/C, one-tap
/// whole-home controls, then devices grouped by room. A viewer-role session sees
/// everything but controls are disabled. Devices briefly highlight on live events.
struct HomeView: View {
    @Environment(AppState.self) private var app
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let globals = app.globals {
                        GlobalsHeader(globals: globals)
                    }
                    if let klima = app.klima, klima.file != nil,
                       !(klima.powerOn?.additionalProperties.isEmpty ?? true) {
                        KlimaCard(klima: klima, state: app.klimaState)
                    }
                    if app.hasLights || app.hasBlinds {
                        WholeHomeCard()
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
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().appLanguage(app.appLanguage) }
            .refreshable { await app.loadDiscovery() }
        }
    }
}

// MARK: - Header

private struct GlobalsHeader: View {
    @Environment(AppState.self) private var app
    let globals: Globals

    var body: some View {
        HStack(spacing: 20) {
            if let crib = app.formatTemp(globals.cribTemp) {
                Label(crib, systemImage: "thermometer.medium")
            }
            if let out = app.formatTemp(globals.outdoorTemp) {
                Label(out, systemImage: "cloud.sun")
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

// MARK: - Air conditioning

private struct KlimaCard: View {
    @Environment(AppState.self) private var app
    let klima: Components.Schemas.Klima
    let state: Components.Schemas.KlimaState?

    @State private var mode = ""
    @State private var temp = 0

    private var programs: [String: [Int]] { klima.powerOn?.additionalProperties ?? [:] }
    private var modes: [String] { programs.keys.sorted() }
    private var temps: [Int] { (programs[mode] ?? []).sorted() }
    private var tempRange: ClosedRange<Int> { (temps.first ?? 16)...(max(temps.first ?? 16, temps.last ?? 30)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Air conditioning", systemImage: "wind").font(.headline)
                Spacer()
                Text(verbatim: pictogram).foregroundStyle(Theme.textSecondary)
            }
            Picker("Mode", selection: $mode) {
                ForEach(modes, id: \.self) { Text(modeLabel($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Temperature").font(.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(verbatim: "\(temp)°").foregroundStyle(Theme.textPrimary)
            }
            TemperatureSlider(celsius: $temp, range: tempRange)
            HStack {
                Spacer()
                Button("Set") { Task { await app.klimaSet(mode: mode, temp: temp) } }
                    .buttonStyle(.borderedProminent)
                Button("Turn off") { Task { await app.klimaOff() } }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(app.isReadOnly)
        .vestaCard()
        .onAppear {
            if mode.isEmpty { mode = state?.mode ?? modes.first ?? "" }
            if temp == 0 { temp = state?.temp ?? temps.first ?? 22 }
        }
        .onChange(of: mode) { _, _ in
            if !temps.contains(temp), let first = temps.first { temp = first }
        }
    }

    private var pictogram: String {
        guard let state, state.power else { return "⏻" }
        let icon = ["cool": "❄️", "heat": "🔥", "auto": "🔄", "dry": "💧", "fan": "🌀"][state.mode ?? ""] ?? "❄️"
        if let t = state.temp { return "\(icon) \(t)°" }
        return icon
    }

    private func modeLabel(_ mode: String) -> LocalizedStringResource {
        switch mode {
        case "cool": "Cool"
        case "heat": "Heat"
        case "auto": "Auto"
        case "dry": "Dry"
        case "fan": "Fan"
        default: "\(mode)"
        }
    }
}

// MARK: - Whole home

private struct WholeHomeCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whole home").font(.headline)
            if app.hasLights {
                HStack {
                    Label("All lights", systemImage: "lightbulb.2").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Turn on") { Task { await app.allLights(on: true) } }.buttonStyle(.bordered)
                    Button("Turn off") { Task { await app.allLights(on: false) } }.buttonStyle(.bordered)
                }
            }
            if app.hasBlinds {
                HStack {
                    Label("All blinds", systemImage: "blinds.horizontal.closed").foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Raise") { Task { await app.allBlinds(up: true) } }.buttonStyle(.bordered)
                    Button("Lower") { Task { await app.allBlinds(up: false) } }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(app.isReadOnly)
        .vestaCard()
    }
}

// MARK: - Rooms

private struct RoomCard: View {
    let room: RoomGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(room.name).font(.headline)
            ForEach(room.devices) { item in
                DeviceRow(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vestaCard()
    }
}

private struct DeviceRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice

    private var highlighted: Bool { app.recentlyChanged.contains(item.id) }

    var body: some View {
        content
            .padding(8)
            .background(
                highlighted ? Theme.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .animation(.easeOut(duration: 0.6), value: highlighted)
    }

    @ViewBuilder private var content: some View {
        switch item.device._type {
        case "light", "plug": SwitchRow(item: item)
        case "blind": BlindRow(item: item)
        case "thermostat": ThermostatRow(item: item)
        default: SensorRow(item: item)
        }
    }
}

private struct SwitchRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice

    var body: some View {
        HStack {
            DeviceLabel(item: item)
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.device._switch ?? false },
                set: { value in Task { await app.toggle(item, on: value) } }
            ))
            .labelsHidden()
            .disabled(app.isReadOnly)
        }
    }
}

private struct BlindRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice
    @State private var percent: Double

    init(item: IdentifiedDevice) {
        self.item = item
        _percent = State(initialValue: item.device.level.map { Double(Control.coverPercent(value: $0)) } ?? 50)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                DeviceLabel(item: item)
                Spacer()
                Image(systemName: percent < 50 ? "blinds.horizontal.closed" : "blinds.horizontal.open")
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.symbolEffect(.replace))
                positionLabel.font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $percent, in: 0...100, step: 1) { editing in
                if !editing { Task { await app.setCover(item, percent: Int(percent)) } }
            }
            .disabled(app.isReadOnly)
        }
        .onChange(of: item.device.level) { _, newLevel in
            // Reflect external changes (e.g. "raise all") in the slider.
            percent = newLevel.map { Double(Control.coverPercent(value: $0)) } ?? percent
        }
    }

    private var positionLabel: Text {
        switch BlindState.from(percent: Int(percent)) {
        case .lowered: return Text("Lowered")
        case .raised: return Text("Raised")
        case .partial(let p): return Text(verbatim: "\(p)%")
        }
    }
}

private struct ThermostatRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice
    @State private var target: Int

    init(item: IdentifiedDevice) {
        self.item = item
        _target = State(initialValue: item.device.setpoint.map { Int($0.rounded()) } ?? 21)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                DeviceLabel(item: item, subtitle: statusLine)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { item.device.thermostatOn ?? false },
                    set: { value in Task { await app.setThermostatPower(item, on: value) } }
                ))
                .labelsHidden()
                .disabled(app.isReadOnly)
            }
            HStack {
                Text("Target \(app.formatSetpoint(target))").font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            TemperatureSlider(celsius: $target, range: 4...28) { value in
                Task { await app.setThermostat(item, celsius: value) }
            }
            .disabled(app.isReadOnly)
        }
        .onChange(of: item.device.setpoint) { _, newSetpoint in
            // Reflect external changes (e.g. turning the thermostat off sets 4°).
            if let setpoint = newSetpoint { target = Int(setpoint.rounded()) }
        }
    }

    private var statusLine: String {
        let detected = app.formatTemp(item.device.temperature)
        let set = item.device.setpoint.map { app.formatSetpoint(Int($0.rounded())) }
        switch (detected, set) {
        case let (d?, s?): return "\(d) → \(s)"
        case let (d?, nil): return d
        case let (nil, s?): return "→ \(s)"
        default: return ""
        }
    }
}

private struct SensorRow: View {
    @Environment(AppState.self) private var app
    let item: IdentifiedDevice

    var body: some View {
        HStack {
            DeviceLabel(item: item)
            Spacer()
            stateText.font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    // Returns a Text (not a String) so localized labels honor the in-app
    // language override via the environment locale, not just the system language.
    private var stateText: Text {
        let device = item.device
        if let door = device.door {
            switch door {
            case "open": return Text("Open")
            case "closed": return Text("Closed")
            default: return Text(verbatim: door)
            }
        }
        if let motion = device.motion {
            return motion ? Text("Motion") : Text("No motion")
        }
        if let temp = app.formatTemp(device.temperature) { return Text(verbatim: temp) }
        return Text(verbatim: "—")
    }
}

/// Device name + a localized type/subtitle line, shared by every row.
private struct DeviceLabel: View {
    let item: IdentifiedDevice
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.displayName).foregroundStyle(Theme.textPrimary)
            Group {
                if let subtitle { Text(verbatim: subtitle) }
                else { Text(typeLabel(item.device._type)) }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private func typeLabel(_ type: String) -> LocalizedStringResource {
        switch type {
        case "light": "Light"
        case "blind": "Blinds"
        case "thermostat": "Thermostat"
        case "plug": "Socket"
        case "motion": "Motion sensor"
        case "door": "Door"
        case "water": "Leak sensor"
        case "smoke": "Smoke sensor"
        default: "Unknown"
        }
    }
}
