import Foundation
import Observation

/// Single source of truth for the app session: which backend, are we
/// authenticated, what's the latest snapshot, and the user prefs. Owns the API
/// client and the live event subscription.
@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case connecting
        case unconfigured            // first run: no backend saved yet — show onboarding, no error
        case needsAuth
        case ready
        case failed(APIError)
    }

    private(set) var phase: Phase = .connecting
    private(set) var whoami: Components.Schemas.WhoAmI?
    private(set) var rooms: [RoomGroup] = []
    private(set) var summary: Summary?
    private(set) var globals: Globals?
    private(set) var klima: Components.Schemas.Klima?
    private(set) var klimaState: Components.Schemas.KlimaState?
    var backendURLString: String = AppConfig.serverURL.absoluteString

    var tempScale: TempScale {
        didSet { UserDefaults.standard.set(tempScale.rawValue, forKey: Self.tempScaleKey) }
    }
    /// nil = follow the system language.
    var appLanguage: String? {
        didSet { UserDefaults.standard.set(appLanguage, forKey: Self.languageKey) }
    }

    /// Node ids whose state changed in the last moment (for a brief highlight).
    private(set) var recentlyChanged: Set<String> = []

    private static let tempScaleKey = "vesta.tempScale"
    private static let languageKey = "vesta.language"

    private let api: any HestiaAPI
    private var eventTask: Task<Void, Never>?
    private var didBootstrap = false

    private var allDevices: [IdentifiedDevice] { rooms.flatMap(\.devices) }
    var isReadOnly: Bool { Control.isReadOnly(role: whoami?.role) }
    var hasLights: Bool { allDevices.contains { $0.device._type == "light" } }
    var hasBlinds: Bool { allDevices.contains { $0.device._type == "blind" } }

    init(api: any HestiaAPI = APIClient()) {
        self.api = api
        tempScale = TempScale(rawValue: UserDefaults.standard.string(forKey: Self.tempScaleKey) ?? "C") ?? .celsius
        appLanguage = UserDefaults.standard.string(forKey: Self.languageKey)
    }

    // MARK: - Session

    /// First entry. No network until the user has actually configured a backend
    /// (so a fresh install / App Review shows a calm onboarding, not an error).
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard BackendURLStore.shared.hasOverride() else {
            phase = .unconfigured
            return
        }
        await connect()
    }

    func connect() async {
        phase = .connecting
        do {
            whoami = try await api.whoami()
            await loadDiscovery()
            startEvents()
        } catch APIError.unauthorized {
            phase = .needsAuth
        } catch {
            phase = .failed(APIError.wrap(error))
        }
    }

    /// Onboarding / "change backend": validate, persist, then connect.
    @discardableResult
    func saveAndConnect(_ raw: String) -> Bool {
        guard let url = BackendURLStore.canonicalize(raw) else { return false }
        BackendURLStore.shared.saveOverride(url)
        backendURLString = url.absoluteString
        eventTask?.cancel()
        let api = self.api
        Task {
            await api.logout()
            await connect()
        }
        return true
    }

    func login(user: String, password: String) async {
        do {
            _ = try await api.login(user: user, password: password)
            whoami = try await api.whoami()
            await loadDiscovery()
            startEvents()
        } catch {
            phase = .failed(APIError.wrap(error))
        }
    }

    func signOut() async {
        eventTask?.cancel()
        await api.logout()
        whoami = nil
        rooms = []
        phase = .needsAuth
    }

    func loadDiscovery() async {
        do {
            let discovery = try await api.discovery()
            rooms = RoomGroup.group(discovery)
            summary = discovery.summary
            globals = discovery.globals
            klima = discovery.klima
            klimaState = discovery.klimaState
            phase = .ready
        } catch APIError.unauthorized {
            phase = .needsAuth
        } catch {
            phase = .failed(APIError.wrap(error))
        }
    }

    // MARK: - Per-device control

    func toggle(_ item: IdentifiedDevice, on: Bool, endpoint: Int? = nil) async {
        await run(on: item) { try await $0.setSwitch(node: $1, on: on, endpoint: endpoint) }
    }

    func setCover(_ item: IdentifiedDevice, percent: Int) async {
        let value = Control.coverValue(percent: percent)
        await run(on: item) { try await $0.setCover(node: $1, value: value) }
    }

    /// Set the target temperature — power on first (like the web UI).
    func setThermostat(_ item: IdentifiedDevice, celsius: Int) async {
        guard let node = Int(item.id) else { return }
        do {
            try await api.setThermostatPower(node: node, on: true)
            try await api.setThermostat(node: node, celsius: celsius)
            await loadDiscovery()
        } catch { phase = .failed(APIError.wrap(error)) }
    }

    /// Power on → just on. Power off → set to 4° first, then off (matches the web UI).
    func setThermostatPower(_ item: IdentifiedDevice, on: Bool) async {
        guard let node = Int(item.id) else { return }
        do {
            if on {
                try await api.setThermostatPower(node: node, on: true)
            } else {
                try await api.setThermostat(node: node, celsius: 4)
                try await api.setThermostatPower(node: node, on: false)
            }
            await loadDiscovery()
        } catch { phase = .failed(APIError.wrap(error)) }
    }

    // MARK: - Air conditioning (klima / IR)

    func klimaSet(mode: String, temp: Int) async {
        guard let file = klima?.file else { return }
        await runIR(file: file, button: Control.klimaButton(mode: mode, temp: temp))
    }

    func klimaOff() async {
        guard let file = klima?.file else { return }
        await runIR(file: file, button: "off")
    }

    // MARK: - Whole-home

    func allLights(on: Bool) async {
        await bulk(type: "light") { try await $0.setSwitch(node: $1, on: on, endpoint: nil) }
    }

    func allBlinds(up: Bool) async {
        let value = up ? 99 : 0
        await bulk(type: "blind") { try await $0.setCover(node: $1, value: value) }
    }

    // MARK: - Display helpers

    func formatTemp(_ celsius: Double?) -> String? {
        celsius.map { Units.format($0, scale: tempScale) }
    }

    func formatSetpoint(_ celsius: Int) -> String {
        Units.format(setpoint: celsius, scale: tempScale)
    }

    // MARK: - Helpers

    private func run(on item: IdentifiedDevice, _ action: @escaping @Sendable (any HestiaAPI, Int) async throws -> Void) async {
        guard let node = Int(item.id) else { return }
        do {
            try await action(api, node)
            await loadDiscovery()
        } catch { phase = .failed(APIError.wrap(error)) }
    }

    private func runIR(file: String, button: String) async {
        do {
            try await api.sendIR(file: file, button: button)
            await loadDiscovery()
        } catch { phase = .failed(APIError.wrap(error)) }
    }

    private func bulk(type: String, _ action: @escaping @Sendable (any HestiaAPI, Int) async throws -> Void) async {
        let nodes = allDevices.filter { $0.device._type == type }.compactMap { Int($0.id) }
        let api = self.api
        await withTaskGroup(of: Void.self) { group in
            for node in nodes { group.addTask { try? await action(api, node) } }
        }
        await loadDiscovery()
    }

    private func startEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await node in EventStream.changes() {
                if let node { self?.markChanged(String(node)) }
                await self?.loadDiscovery()
            }
        }
    }

    /// Flag a node as just-changed, then clear it after a beat so the UI can fade
    /// a brief highlight.
    private func markChanged(_ id: String) {
        recentlyChanged.insert(id)
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            recentlyChanged.remove(id)
        }
    }
}
