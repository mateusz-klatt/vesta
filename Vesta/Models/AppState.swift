import Foundation
import Observation

enum RefreshSource {
    case initialAuth, foreground, userPull, denial
}

enum DiscoveryOutcome: Equatable {
    case loaded, denied, unauthenticated, transientFailure, cancelledOrStale
}

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
    private(set) var capabilities: Capabilities?
    private(set) var receiptAccessGeneration = 0
    private(set) var notice: APIError?
    var whoami: Components.Schemas.WhoAmI? {
        capabilities.map { .init(role: $0.legacyRole, user: $0.user) }
    }
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
    let receiptPairing: ReceiptPairing
    private let makeEvents: @Sendable () -> AsyncStream<EventStream.Event>
    private let eventRetryDelay: @Sendable (Duration) async throws -> Void
    private(set) var eventTask: Task<Void, Never>?
    private var eventRunID: UUID?
    private var eventStage: EventStage?
    private var isInForeground = true
    private var lifecycleGeneration = 0
    private var didBootstrap = false
    /// Bumped on sign-out and backend change so a login still in flight
    /// can't pair against the new session.
    private var sessionGeneration = 0
    private var capabilitiesGeneration = 0
    private var discoveryGeneration = 0
    private var activeCapabilitiesRefresh: CapabilityRefresh?
    @ObservationIgnored private weak var openReceiptFlow: ReceiptFlow?
    /// The logout (and unpair) a backend change runs. A login waits for it, or
    /// that deferred logout would cancel the new session's login.
    private var resetTask: Task<Void, Never>?
    private weak var activeBudgetStore: BudgetStore?

    private struct DiscoveryFence: Equatable {
        let session: Int
        let discovery: Int
    }

    private struct Fence: Equatable {
        let discovery: DiscoveryFence
        let capabilities: Int
    }

    private enum EventStage {
        case opening(Fence)
        case connected
        case backingOff
    }

    private struct CapabilityRefresh {
        let id: UUID
        let source: RefreshSource
        let fence: Fence
        let task: Task<Fence?, Never>
    }

    private var currentDiscoveryFence: DiscoveryFence {
        DiscoveryFence(session: sessionGeneration, discovery: discoveryGeneration)
    }

    private var currentFence: Fence {
        Fence(discovery: currentDiscoveryFence, capabilities: capabilitiesGeneration)
    }

    private func isCurrent(_ fence: Fence) -> Bool {
        !Task.isCancelled && fence == currentFence
    }

    private func isCurrentDiscovery(_ fence: DiscoveryFence) -> Bool {
        !Task.isCancelled && fence == currentDiscoveryFence && canViewIOC
    }

    private var allDevices: [IdentifiedDevice] { rooms.flatMap(\.devices) }
    var canViewIOC: Bool { capabilities?.canViewIOC == true }
    var isReadOnly: Bool { capabilities?.canControlIOC != true }
    var receiptsAPI: (any ReceiptsAPI)? {
        guard capabilities?.canUseReceipts == true, let api = api as? any ReceiptsAPI else { return nil }
        let session = sessionGeneration
        let access = receiptAccessGeneration
        return DenialReportingReceiptsAPI(api: api) { [weak self] in
            guard let self, hasReceiptAccess(session: session, generation: access) else { return nil }
            return { [weak self] in
                guard let self, hasReceiptAccess(session: session, generation: access) else { return }
                reportDenial()
            }
        }
    }

    private func hasReceiptAccess(session: Int, generation: Int) -> Bool {
        sessionGeneration == session && receiptAccessGeneration == generation && capabilities?.canUseReceipts == true
    }


    /// Native budget reads stay hidden until hestia advertises
    /// `budget_native_read` and capabilities grant `budget.view` (V2 plan §10).
    /// Nothing in production turns this on yet; tests do.
    var nativeBudgetEnabled = false
    var budgetAPI: (any BudgetAPI)? {
        guard nativeBudgetEnabled, capabilities?.effectiveDeviceEligiblePermissions.contains(.budgetView) == true else { return nil }
        return api as? any BudgetAPI
    }

    func makeBudgetStore(now: Date = Date()) -> BudgetStore? {
        guard let api = budgetAPI else { return nil }
        closeBudget()
        let store = BudgetStore(api: api, now: now)
        activeBudgetStore = store
        return store
    }

    func closeBudget() {
        activeBudgetStore?.clear()
        activeBudgetStore = nil
    }
    var hasLights: Bool { allDevices.contains { $0.device._type == "light" } }
    var hasBlinds: Bool { allDevices.contains { $0.device._type == "blind" } }

    func makeReceiptFlow() -> ReceiptFlow? {
        guard let api = receiptsAPI else { return nil }
        let session = sessionGeneration
        let access = receiptAccessGeneration
        let flow = ReceiptFlow(api: api, allowsMatching: { [weak self] in
            guard let self, hasReceiptAccess(session: session, generation: access) else { return false }
            return capabilities?.canMatchReceipts == true
        })
        openReceiptFlow = flow
        return flow
    }

    init(api: (any HestiaAPI)? = nil,
         receiptPairing: ReceiptPairing = ReceiptPairing(),
         events: @escaping @Sendable () -> AsyncStream<EventStream.Event> = { EventStream.changes() },
         eventRetryDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.receiptPairing = receiptPairing
        self.api = api ?? APIClient(receiptPairing: receiptPairing)
        self.makeEvents = events
        self.eventRetryDelay = eventRetryDelay
        tempScale = TempScale(rawValue: UserDefaults.standard.string(forKey: Self.tempScaleKey) ?? "C") ?? .celsius
        appLanguage = UserDefaults.standard.string(forKey: Self.languageKey)
    }

    // MARK: - Session

    /// First entry. No network until the user has actually configured a backend
    /// (so a fresh install / App Review shows a calm onboarding, not an error).
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        #if DEBUG
        // Screenshot/demo bootstrap: `-vesta.url <url> [-vesta.user u -vesta.pass p]`.
        // DEBUG-only — stripped from Release builds.
        if let url = Self.launchValue("-vesta.url"), let canonical = BackendURLStore.canonicalize(url) {
            BackendURLStore.shared.saveOverride(canonical)
            backendURLString = canonical.absoluteString
            if let user = Self.launchValue("-vesta.user"), let pass = Self.launchValue("-vesta.pass") {
                await login(user: user, password: pass)
            } else {
                await connect()
            }
            return
        }
        #endif
        guard BackendURLStore.shared.hasOverride() else {
            phase = .unconfigured
            return
        }
        await connect()
    }

    #if DEBUG
    private static func launchValue(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    func connect() async {
        receiptPairing.refreshStatus()
        guard !Task.isCancelled else { return }
        prepareInitialAuth()
        await finishInitialAuth()
    }

    /// Onboarding / "change backend": validate, persist, then connect.
    @discardableResult
    func saveAndConnect(_ raw: String) -> Bool {
        guard let url = BackendURLStore.canonicalize(raw) else { return false }
        sessionGeneration += 1
        let generation = sessionGeneration
        let changed = url != AppConfig.serverURL
        BackendURLStore.shared.saveOverride(url)
        backendURLString = url.absoluteString
        prepareInitialAuth()
        let api = self.api
        let previous = resetTask
        resetTask = Task {
            await previous?.value
            if changed { try? await receiptPairing.unpair() }
            await api.logout()
            guard generation == sessionGeneration else { return }
            await connect()
        }
        return true
    }

    func login(user: String, password: String) async {
        // Captured before waiting, so a sign-out or another backend change
        // during the wait still supersedes this attempt.
        let generation = sessionGeneration
        await resetTask?.value
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        sessionGeneration += 1
        let loginGeneration = sessionGeneration
        receiptPairing.refreshStatus()
        let server = receiptPairing.server
        prepareInitialAuth()
        let fence = currentFence
        do {
            _ = try await api.login(user: user, password: password)
        } catch {
            guard isCurrent(fence), !APIError.isCancellation(error) else { return }
            phase = .failed(APIError.wrap(error))
            return
        }
        guard isCurrent(fence) else { return }
        await finishInitialAuth()
        guard loginGeneration == sessionGeneration, !Task.isCancelled else { return }
        await pairReceiptsAfterLogin(user: user, password: password, server: server)
    }

    private func prepareInitialAuth() {
        clearAuthorization()
        phase = .connecting
    }

    private func finishInitialAuth() async {
        guard let fence = await refreshCapabilities(source: .initialAuth), isCurrent(fence) else { return }
        guard canViewIOC else {
            phase = .ready
            return
        }
        if await loadDiscovery(failingOnTransient: true) == .loaded, isCurrentDiscovery(fence.discovery) {
            startEvents()
        }
    }

    /// Admins get a receipts device token from the same credentials, so they
    /// don't have to copy a pairing code. Any failure leaves the code flow.
    private func pairReceiptsAfterLogin(user: String, password: String, server: URL) async {
        guard capabilities?.canUseReceipts == true, receiptPairing.status != .paired else { return }
        try? await receiptPairing.pair(username: user, password: password,
                                       deviceName: ReceiptPairing.deviceName, server: server)
    }

    func signOut() async {
        sessionGeneration += 1
        let generation = sessionGeneration
        prepareInitialAuth()
        try? await receiptPairing.unpair()
        await api.logout()
        guard generation == sessionGeneration else { return }
        phase = .needsAuth
    }

    private func invalidateSession() {
        sessionGeneration += 1
        clearAuthorization()
        phase = .needsAuth
        // Login waits for local credential invalidation just as it waits for reset.
        let api = self.api
        let previous = resetTask
        resetTask = Task {
            await previous?.value
            await api.invalidateSession()
        }
    }

    private func clearAuthorization() {
        closeBudget()
        activeCapabilitiesRefresh?.task.cancel()
        activeCapabilitiesRefresh = nil
        publishCapabilities(nil)
        notice = nil
    }

    // MARK: - Capabilities

    private func refreshCapabilities(source: RefreshSource) async -> Fence? {
        guard !Task.isCancelled, let task = beginCapabilityRefresh(source: source) else { return nil }
        return await task.value
    }

    private func beginCapabilityRefresh(source: RefreshSource) -> Task<Fence?, Never>? {
        let expectedPhase: Phase = source == .initialAuth ? .connecting : .ready
        guard phase == expectedPhase else { return nil }
        let fence = currentFence
        // A denial needs an answer requested after the rejection. Explicit
        // refreshes own their follow-up work, so only like denials can share it.
        if let active = activeCapabilitiesRefresh, active.fence == fence,
           source == .denial, active.source == .denial {
            return active.task
        }
        activeCapabilitiesRefresh?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await self?.performCapabilityRefresh(id: id, source: source, fence: fence, phase: expectedPhase)
        }
        activeCapabilitiesRefresh = CapabilityRefresh(id: id, source: source, fence: fence, task: task)
        return task
    }

    private func performCapabilityRefresh(id: UUID, source: RefreshSource, fence: Fence, phase expectedPhase: Phase) async -> Fence? {
        defer {
            if activeCapabilitiesRefresh?.id == id { activeCapabilitiesRefresh = nil }
        }
        guard isCurrent(fence), phase == expectedPhase else { return nil }
        do {
            let resolved = try await api.capabilities()
            guard isCurrent(fence), phase == expectedPhase else { return nil }
            publishCapabilities(resolved)
            if source == .foreground || source == .userPull { notice = nil }
            return currentFence
        } catch {
            guard isCurrent(fence), phase == expectedPhase, !APIError.isCancellation(error) else { return nil }
            switch APIError.wrap(error) {
            case .unauthorized:
                invalidateSession()
            case .forbidden:
                publishCapabilities(nil)
                if phase == .connecting {
                    phase = .failed(.forbidden)
                } else {
                    notice = .forbidden
                }
            case let failure:
                if phase == .connecting { phase = .failed(failure) }
            }
            return nil
        }
    }

    private func publishCapabilities(_ published: Capabilities?) {
        if capabilities != published { capabilitiesGeneration += 1 }
        if capabilities?.canUseReceipts == true, published?.canUseReceipts != true {
            receiptAccessGeneration += 1
        }
        capabilities = published
        applyIOCGrant(published?.canViewIOC == true)
        openReceiptFlow?.updateMatchAccess()
    }

    private func applyIOCGrant(_ granted: Bool) {
        if !granted { clearIOC() }
    }

    private func clearIOC() {
        discoveryGeneration += 1
        stopEvents()
        rooms = []
        summary = nil
        globals = nil
        klima = nil
        klimaState = nil
        recentlyChanged = []
    }

    private func reportDenial() {
        notice = .forbidden
        _ = beginCapabilityRefresh(source: .denial)
    }

    // MARK: - App lifecycle

    /// Recheck authorization before replacing the socket iOS suspended.
    func enterForeground() {
        isInForeground = true
        lifecycleGeneration += 1
        receiptPairing.refreshStatus()
        guard phase == .ready else { return }
        let session = sessionGeneration
        let lifecycle = lifecycleGeneration
        Task { [weak self] in
            guard let self, session == sessionGeneration, lifecycle == lifecycleGeneration,
                  let fence = await refreshCapabilities(source: .foreground),
                  isCurrent(fence), lifecycle == lifecycleGeneration, canViewIOC else { return }
            startEvents()
        }
    }

    /// Going to the background: drop the subscription (it would die anyway), so we
    /// don't hold a dead connection or spin reconnect attempts while suspended.
    func enterBackground() {
        isInForeground = false
        lifecycleGeneration += 1
        stopEvents()
    }

    func refresh() async {
        guard let fence = await refreshCapabilities(source: .userPull), isCurrent(fence), canViewIOC else { return }
        guard await loadDiscovery() == .loaded, isCurrentDiscovery(fence.discovery) else { return }
        switch eventStage {
        case nil, .backingOff:
            startEvents(after: fence.discovery)
        case .opening(let openingFence) where openingFence != currentFence:
            startEvents(after: fence.discovery)
        case .opening, .connected:
            break
        }
    }

    @discardableResult
    func loadDiscovery(failingOnTransient: Bool = false) async -> DiscoveryOutcome {
        let fence = currentDiscoveryFence
        guard isCurrentDiscovery(fence) else { return .cancelledOrStale }
        do {
            let discovery = try await api.discovery()
            guard isCurrentDiscovery(fence) else { return .cancelledOrStale }
            rooms = RoomGroup.group(discovery)
            summary = discovery.summary
            globals = discovery.globals
            klima = discovery.klima
            klimaState = discovery.klimaState
            if phase == .connecting { phase = .ready }
            return .loaded
        } catch {
            guard isCurrentDiscovery(fence), !APIError.isCancellation(error) else { return .cancelledOrStale }
            switch APIError.wrap(error) {
            case .forbidden:
                stopForIOCDenial()
                return .denied
            case .unauthorized:
                invalidateSession()
                return .unauthenticated
            case let failure:
                if failingOnTransient { fail(failure) }
                return .transientFailure
            }
        }
    }

    private func stopForIOCDenial() {
        clearIOC()
        phase = .ready
        reportDenial()
    }

    private func fail(_ error: APIError) {
        discoveryGeneration += 1
        stopEvents()
        phase = .failed(error)
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
        await runControl { fence in
            try await api.setThermostatPower(node: node, on: true)
            guard isCurrent(fence) else { return }
            try await api.setThermostat(node: node, celsius: celsius)
        }
    }

    /// Power on → just on. Power off → set to 4° first, then off (matches the web UI).
    func setThermostatPower(_ item: IdentifiedDevice, on: Bool) async {
        guard let node = Int(item.id) else { return }
        await runControl { fence in
            if !on {
                try await api.setThermostat(node: node, celsius: 4)
                guard isCurrent(fence) else { return }
            }
            try await api.setThermostatPower(node: node, on: on)
        }
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

    // Whole-home sweeps are a single server-side scene, never a client-side
    // fan-out: the registry's opt-out list (exclude_from_all / per-gang
    // endpoint_exclude) is deliberately not exposed to clients, so only the
    // server can skip excluded devices/gangs (and pick level-vs-switch for
    // dimmable lights).

    func allLights(on: Bool) async {
        await runScene(on ? .lightsOn : .lightsOff)
    }

    func allBlinds(up: Bool) async {
        await runScene(up ? .blindsUp : .blindsDown)
    }

    /// Set every (non-excluded) blind to one position via the server scene. The UI
    /// works in display %, so map through the perceptual curve to a wire value here.
    func setAllBlinds(percent: Int) async {
        await runScene(.blindsSet, value: Control.coverValue(percent: percent))
    }

    /// Mean displayed openness across the blinds that report a position, for the
    /// whole-home slider to live-track. `nil` when none report yet, so the UI can
    /// park the handle at a neutral 50 % without inventing a "50 %" readout.
    var averageBlindPercent: Int? {
        let percents = allDevices
            .filter { $0.device._type == "blind" }
            .compactMap { $0.device.level.map { Control.coverPercent(value: $0) } }
        guard !percents.isEmpty else { return nil }
        return Int((Double(percents.reduce(0, +)) / Double(percents.count)).rounded())
    }

    // MARK: - Display helpers

    func formatTemp(_ celsius: Double?) -> String? {
        celsius.map { Units.format($0, scale: tempScale) }
    }

    func formatSetpoint(_ celsius: Int) -> String {
        Units.format(setpoint: celsius, scale: tempScale)
    }

    // MARK: - Helpers

    private func run(on item: IdentifiedDevice, _ action: @Sendable (any HestiaAPI, Int) async throws -> Void) async {
        guard let node = Int(item.id) else { return }
        await runControl { _ in try await action(api, node) }
    }

    private func runIR(file: String, button: String) async {
        await runControl { _ in try await api.sendIR(file: file, button: button) }
    }

    private func runScene(_ op: Components.Schemas.SceneRequest.OpPayload, value: Int? = nil) async {
        await runControl { _ in try await api.scene(op, value: value) }
    }

    private func runControl(_ action: (Fence) async throws -> Void) async {
        let fence = currentFence
        guard !Task.isCancelled else { return }
        do {
            try await action(fence)
            guard isCurrent(fence) else { return }
            await loadDiscovery(failingOnTransient: true)
        } catch {
            guard isCurrent(fence), !APIError.isCancellation(error) else { return }
            switch APIError.wrap(error) {
            case .forbidden: reportDenial()
            case .unauthorized: invalidateSession()
            case let failure: fail(failure)
            }
        }
    }

    private func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
        eventRunID = nil
        eventStage = nil
    }

    private func startEvents(after snapshot: DiscoveryFence? = nil) {
        guard isInForeground, phase == .ready, canViewIOC else { return }
        stopEvents()
        let id = UUID()
        eventRunID = id
        eventStage = .opening(currentFence)
        eventTask = Task { [weak self] in
            guard let self else { return }
            await runEvents(id: id, initialSnapshot: snapshot)
        }
    }

    /// SSE carries future events. Each connection starts with a current snapshot
    /// to catch up on changes made while the socket was closed.
    private func runEvents(id: UUID, initialSnapshot: DiscoveryFence?) async {
        defer {
            if eventRunID == id { stopEvents() }
        }
        var snapshot = initialSnapshot
        var backoff = Duration.seconds(1)
        while !Task.isCancelled, eventRunID == id, canViewIOC {
            let streamFence = currentDiscoveryFence
            eventStage = .opening(currentFence)
            let outcome: DiscoveryOutcome
            if let initial = snapshot {
                guard isCurrentDiscovery(initial) else { return }
                snapshot = nil
                outcome = .loaded
            } else {
                outcome = await loadDiscovery()
            }
            switch outcome {
            case .loaded:
                guard await consumeEvents(id: id, fence: streamFence, backoff: &backoff) else { return }
            case .transientFailure:
                break
            case .denied, .unauthenticated, .cancelledOrStale:
                return
            }
            guard isCurrentDiscovery(streamFence), eventRunID == id else { return }
            eventStage = .backingOff
            do {
                try await eventRetryDelay(backoff)
            } catch {
                return
            }
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    /// Returns whether the current IOC subscription may reconnect.
    private func consumeEvents(id: UUID, fence: DiscoveryFence, backoff: inout Duration) async -> Bool {
        guard isCurrentDiscovery(fence), eventRunID == id else { return false }
        for await event in makeEvents() {
            guard isCurrentDiscovery(fence), eventRunID == id else { return false }
            switch event {
            case .connected:
                eventStage = .connected
                backoff = .seconds(1)
            case .change(let node):
                if let node { markChanged(String(node)) }
                switch await loadDiscovery() {
                case .loaded: continue
                case .transientFailure: return true
                case .denied, .unauthenticated, .cancelledOrStale: return false
                }
            case .forbidden:
                stopForIOCDenial()
                return false
            case .unauthorized:
                invalidateSession()
                return false
            }
        }
        return true
    }

    /// Flag a node as just-changed, then clear it after a beat so the UI can fade
    /// a brief highlight.
    private func markChanged(_ id: String) {
        recentlyChanged.insert(id)
        let fence = currentDiscoveryFence
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            guard currentDiscoveryFence == fence else { return }
            recentlyChanged.remove(id)
        }
    }
}
