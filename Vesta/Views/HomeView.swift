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
            #if DEBUG
            .onAppear {
                // Screenshot automation: auto-present Settings for layout capture.
                if ProcessInfo.processInfo.arguments.contains("-vesta.openSettings") { showSettings = true }
            }
            #endif
        }
    }
}

// MARK: - Header

private struct GlobalsHeader: View {
    @Environment(AppState.self) private var app
    let globals: Globals

    // Outdoor temp + humidity come from one 433 feeder, whose battery flag rides along;
    // render the block if any of the three has something to say (so a low battery still
    // shows even if the temp reading is momentarily absent).
    private var showOutdoor: Bool {
        globals.outdoorTemp != nil || globals.outdoorHumidity != nil || globals.outdoorBatteryOk == false
    }

    var body: some View {
        // Tick once a minute so "N ago" keeps counting up and a reading crosses into
        // "stale" (red) even when nothing else refreshes the snapshot — a silent sensor
        // fires no event of its own. TimelineView pauses off-screen and while backgrounded,
        // so it's free when unseen (a coarse 60 s beat is plenty for a minute-grained badge).
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(alignment: .top, spacing: 20) {
                if let crib = app.formatTemp(globals.cribTemp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(crib, systemImage: "thermometer.medium")
                        // Mains baby-monitor: no battery flag.
                        FreshnessBadge(ts: globals.cribTempTs, now: context.date)
                    }
                }
                if showOutdoor {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Label(app.formatTemp(globals.outdoorTemp) ?? "—", systemImage: "cloud.sun")
                            if let hum = globals.outdoorHumidity {
                                Text(verbatim: "\(Int(hum))%").foregroundStyle(Theme.textSecondary)
                            }
                        }
                        // Local 433 feeder: temp + humidity share one battery.
                        FreshnessBadge(ts: globals.outdoorTempTs, batteryOk: globals.outdoorBatteryOk, now: context.date)
                    }
                }
                Spacer()
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textPrimary)
        .vestaCard()
    }
}

/// The freshness / battery line under a globals sensor reading: a muted "N ago"
/// that turns red when the last sample is stale or the sensor's battery is low —
/// mirroring hestia's `freshnessMeta` badge. Renders nothing until the sensor has
/// sampled (and its battery is fine); the reading's absence already says "no data".
/// `now` is supplied by the parent's minute clock so the age (and the stale flip) stay live.
private struct FreshnessBadge: View {
    @Environment(\.locale) private var locale
    let ts: String?
    var batteryOk: Bool?
    let now: Date

    var body: some View {
        let meta = Freshness.evaluate(ts: ts, batteryOk: batteryOk, now: now)
        if meta.hasBadge {
            HStack(spacing: 5) {
                if let sampledAt = meta.sampledAt {
                    Text(sampledAt.formatted(
                        Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated).locale(locale)
                    ))
                }
                if meta.sampledAt != nil && meta.batteryLow {
                    Text(verbatim: "·")
                }
                if meta.batteryLow {
                    Text(verbatim: "🪫 ") + Text("Low battery")
                }
            }
            .font(.caption2)
            .foregroundStyle(meta.warn ? Color.red : Theme.textSecondary)
        }
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
                Text(verbatim: app.formatSetpoint(temp)).foregroundStyle(Theme.textPrimary)
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
        if let t = state.temp { return "\(icon) \(app.formatSetpoint(t))" }
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
                VStack(spacing: 8) {
                    HStack {
                        Label("All blinds", systemImage: "blinds.horizontal.closed").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Raise") { Task { await app.allBlinds(up: true) } }.buttonStyle(.bordered)
                        Button("Lower") { Task { await app.allBlinds(up: false) } }.buttonStyle(.bordered)
                    }
                    AllBlindsSlider(initial: app.averageBlindPercent ?? 50)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(app.isReadOnly)
        .vestaCard()
    }
}

/// Whole-home blind position: one server scene sets every (non-excluded) blind.
/// The handle live-tracks the average reported position, mirroring the per-room row.
private struct AllBlindsSlider: View {
    @Environment(AppState.self) private var app
    @State private var percent: Double
    @State private var isEditing = false
    @State private var isSending = false

    init(initial: Int) { _percent = State(initialValue: Double(initial)) }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $percent, in: 0...100, step: 1) { editing in
                isEditing = editing
                if !editing {
                    Task {
                        isSending = true
                        await app.setAllBlinds(percent: Int(percent))
                        isSending = false
                    }
                }
            }
            .disabled(app.isReadOnly)
            Text(verbatim: readout)
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .onChange(of: app.averageBlindPercent) { _, average in
            // Follow the reported average when idle, so a sweep or external move updates
            // the handle — but never fight an active drag or an in-flight send, or a
            // stray snapshot would yank the handle out from under the user (this mirrors
            // hestia's `busy || activeElement === slider` re-sync skip).
            guard !isEditing, !isSending, let average else { return }
            percent = Double(average)
        }
    }

    // Show the live handle % while dragging; otherwise the reported average, or a dash
    // when no blind reports a position (never a fabricated "50 %").
    private var readout: String {
        if isEditing || app.averageBlindPercent != nil { return "\(Int(percent))%" }
        return "—"
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

    private var gangs: [Gangs.Gang] {
        Gangs.list(states: item.device.endpoints?.additionalProperties,
                   names: item.device.endpointNames?.additionalProperties)
    }

    var body: some View {
        if gangs.isEmpty {
            singleToggle
        } else {
            multiGang
        }
    }

    /// Plain single-gang switch: one toggle on the aggregate `switch`.
    private var singleToggle: some View {
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

    /// Multi-gang switch: the device name once, then one toggle per channel.
    private var multiGang: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeviceLabel(item: item)
            ForEach(gangs) { gang in
                HStack {
                    gangLabel(gang).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 16)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { item.device.endpoints?.additionalProperties[String(gang.key)] ?? false },
                        set: { value in Task { await app.toggle(item, on: value, endpoint: gang.key) } }
                    ))
                    .labelsHidden()
                    .disabled(app.isReadOnly)
                }
            }
        }
    }

    private func gangLabel(_ gang: Gangs.Gang) -> Text {
        gang.name.isEmpty ? Text("Channel \(gang.key)") : Text(verbatim: gang.name)
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
