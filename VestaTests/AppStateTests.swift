import XCTest
import Synchronization
@testable import Vesta

/// Records every call and can hold a response across a session change.
actor MockHestiaAPI: HestiaAPI, ReceiptsAPI, ReceiptReviewAPI {
    enum Call: Equatable {
        case whoami, capabilities, discovery, logout
        case login(String, String)
        case setSwitch(Int, Bool, Int?)
        case setCover(Int, Int)
        case scene(Components.Schemas.SceneRequest.OpPayload, Int?)
        case setThermostat(Int, Int)
        case setThermostatPower(Int, Bool)
        case sendIR(String, String)
        case parseReceipt
    }

    struct CapabilityRequest: Equatable, Sendable {
        let origin: URL
        let features: ServerFeatures
    }

    private(set) var calls: [Call] = []
    private(set) var calendarStub: (any CalendarAPI)?
    private(set) var budgetStub: (any BudgetAPI)?
    private(set) var receiptReviewStub: (any ReceiptReviewAPI)?
    private(set) var probeOrigins: [URL] = []
    private(set) var logoutsFinishedAtProbe: [Int] = []
    private(set) var capabilityRequests: [CapabilityRequest] = []
    private(set) var legacyVerificationRequests: [BoundSession] = []
    private(set) var logoutCredentials: [BoundSession] = []
    private var probeResult: Result<ServerFeatures, URLError> = .success(.legacy)
    private var holdProbe = false
    private var probeGate: CheckedContinuation<Void, Never>?
    private var whoamiResult = Components.Schemas.WhoAmI(role: "operator", user: "u")
    private var capabilitiesResult: Result<Capabilities, APIError>?
    private var holdCapabilities = false
    private var capabilitiesGate: CheckedContinuation<Void, Never>?
    private var discoveryResult: Result<Components.Schemas.Discovery, any Error> = .failure(APIError.http(599))
    private var sceneError: APIError?
    private var holdScene = false
    private var sceneGate: CheckedContinuation<Void, Never>?
    private var holdLogin = false
    private var loginGate: CheckedContinuation<Void, Never>?
    private var loginError: APIError?
    private var holdLogout = false
    private(set) var logoutsFinished = 0
    private(set) var logoutsFinishedAtLogin: Int?
    private var logoutGate: CheckedContinuation<Void, Never>?
    private var holdDiscovery = false
    private var discoveryGate: CheckedContinuation<Void, Never>?
    private var receiptParseResult: Result<ReceiptParseResult, ReceiptError> = .failure(.forbidden)
    private var holdReceiptParse = false
    private var receiptParseGate: CheckedContinuation<Void, Never>?

    func setWhoami(role: String?) {
        whoamiResult = .init(role: role, user: "u")
        capabilitiesResult = nil
    }
    func setAuthOff() {
        whoamiResult = .init(role: nil, user: nil)
        capabilitiesResult = nil
    }
    func setFeatures(_ features: ServerFeatures) { probeResult = .success(features) }
    func setFeatures(_ features: Set<ServerFeature>) {
        setFeatures(.init(authContract: 2, features: features, qrOrigin: nil, isLegacy: false))
    }
    func setProbeError(_ error: URLError) { probeResult = .failure(error) }
    func setHoldProbe() { holdProbe = true }
    var isProbeHeld: Bool { probeGate != nil }
    func releaseProbe() {
        holdProbe = false
        probeGate?.resume()
        probeGate = nil
    }
    func setCapabilities(_ capabilities: Capabilities) { capabilitiesResult = .success(capabilities) }
    func setCapabilitiesError(_ error: APIError) { capabilitiesResult = .failure(error) }
    func setCalendarStub(_ calendar: any CalendarAPI) { calendarStub = calendar }
    func setBudgetStub(_ budget: (any BudgetAPI)?) { budgetStub = budget }
    func setReceiptReviewStub(_ review: (any ReceiptReviewAPI)?) { receiptReviewStub = review }
    func setHoldCapabilities() { holdCapabilities = true }
    var isCapabilitiesHeld: Bool { capabilitiesGate != nil }
    func releaseCapabilities() {
        holdCapabilities = false
        capabilitiesGate?.resume()
        capabilitiesGate = nil
    }
    func setDiscovery(_ discovery: Components.Schemas.Discovery) { discoveryResult = .success(discovery) }
    func setDiscoveryError(_ error: any Error) { discoveryResult = .failure(error) }
    func setSceneError(_ error: APIError) { sceneError = error }
    func setHoldScene() { holdScene = true }
    var isSceneHeld: Bool { sceneGate != nil }
    func releaseScene() {
        holdScene = false
        sceneGate?.resume()
        sceneGate = nil
    }
    func setHoldLogin() { holdLogin = true }
    func releaseLogin() {
        holdLogin = false
        loginGate?.resume()
        loginGate = nil
    }
    func setLoginError(_ error: APIError) { loginError = error }
    func setHoldLogout() { holdLogout = true }
    var isLogoutHeld: Bool { logoutGate != nil }
    func releaseLogout() {
        holdLogout = false
        logoutGate?.resume()
        logoutGate = nil
    }
    func setHoldDiscovery() { holdDiscovery = true }
    var isDiscoveryHeld: Bool { discoveryGate != nil }
    func releaseDiscovery() {
        holdDiscovery = false
        discoveryGate?.resume()
        discoveryGate = nil
    }
    func setReceiptParseResult(_ result: ReceiptParseResult) { receiptParseResult = .success(result) }
    func setReceiptParseError(_ error: ReceiptError) { receiptParseResult = .failure(error) }
    func setHoldReceiptParse() { holdReceiptParse = true }
    var isReceiptParseHeld: Bool { receiptParseGate != nil }
    func releaseReceiptParse() {
        holdReceiptParse = false
        receiptParseGate?.resume()
        receiptParseGate = nil
    }

    func count(_ call: Call) -> Int { calls.filter { $0 == call }.count }

    func whoami() async throws -> Components.Schemas.WhoAmI { calls.append(.whoami); return whoamiResult }
    func probeFeatures(on origin: URL) async throws -> ServerFeatures {
        probeOrigins.append(origin)
        logoutsFinishedAtProbe.append(logoutsFinished)
        let result = probeResult
        if holdProbe {
            holdProbe = false
            await withCheckedContinuation { probeGate = $0 }
        }
        return try result.get()
    }
    func capabilities(on origin: URL, features: ServerFeatures) async throws -> Capabilities {
        calls.append(.capabilities)
        capabilityRequests.append(.init(origin: origin, features: features))
        let result = capabilitiesResult ?? .success(.fromLegacyRole(role: whoamiResult.role, user: whoamiResult.user))
        if holdCapabilities {
            holdCapabilities = false
            await withCheckedContinuation { capabilitiesGate = $0 }
        }
        return try result.get()
    }
    func verifyLegacySession(_ session: BoundSession, features: ServerFeatures) async throws -> Capabilities {
        legacyVerificationRequests.append(session)
        return try await capabilities(on: session.origin, features: features)
    }
    func discovery() async throws -> Components.Schemas.Discovery {
        calls.append(.discovery)
        let result = discoveryResult
        if holdDiscovery {
            holdDiscovery = false
            await withCheckedContinuation { discoveryGate = $0 }
        }
        return try result.get()
    }
    @discardableResult
    func login(user: String, password: String, on origin: URL) async throws -> Components.Schemas.LoginSuccess {
        calls.append(.login(user, password))
        logoutsFinishedAtLogin = logoutsFinished
        if holdLogin {
            holdLogin = false
            await withCheckedContinuation { loginGate = $0 }
        }
        if let loginError { throw loginError }
        return .init(ok: true, token: "t", user: user)
    }
    func remoteLogout(token: String, origin: URL) async {
        calls.append(.logout)
        logoutCredentials.append(BoundSession(origin: origin, actor: nil, token: token))
        if holdLogout { await withCheckedContinuation { logoutGate = $0 } }
        logoutsFinished += 1
    }
    func setSwitch(node: Int, on: Bool, endpoint: Int?) async throws { calls.append(.setSwitch(node, on, endpoint)) }
    func setCover(node: Int, value: Int) async throws { calls.append(.setCover(node, value)) }
    func scene(_ op: Components.Schemas.SceneRequest.OpPayload, value: Int?) async throws {
        calls.append(.scene(op, value))
        let error = sceneError
        if holdScene {
            holdScene = false
            await withCheckedContinuation { sceneGate = $0 }
        }
        if let error { throw error }
    }
    func setThermostat(node: Int, celsius: Int) async throws { calls.append(.setThermostat(node, celsius)) }
    func setThermostatPower(node: Int, on: Bool) async throws { calls.append(.setThermostatPower(node, on)) }
    func sendIR(file: String, button: String) async throws { calls.append(.sendIR(file, button)) }

    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult {
        calls.append(.parseReceipt)
        let result = receiptParseResult
        if holdReceiptParse {
            holdReceiptParse = false
            await withCheckedContinuation { receiptParseGate = $0 }
        }
        return try result.get()
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail {
        throw ReceiptError.forbidden
    }

    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws {
        throw ReceiptError.forbidden
    }

    func listReviewReceipts(
        cursor: ReceiptReviewCursor?, firstPageFilter: ReceiptReviewListFilter, scope: ReceiptSessionScope
    ) async throws -> ReceiptReviewPage {
        guard let receiptReviewStub else { throw ReceiptError.forbidden }
        return try await receiptReviewStub.listReviewReceipts(cursor: cursor, firstPageFilter: firstPageFilter, scope: scope)
    }

    func receiptDetail(id: String, scope: ReceiptSessionScope) async throws -> ReceiptDetailResult {
        guard let receiptReviewStub else { throw ReceiptError.forbidden }
        return try await receiptReviewStub.receiptDetail(id: id, scope: scope)
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail {
        guard let receiptReviewStub else { throw ReceiptError.forbidden }
        return try await receiptReviewStub.confirmImportedReceipt(request, scope: scope)
    }
}

private actor MockQRLogin {
    private(set) var origins: [URL] = []
    private var hold = false
    private var gate: CheckedContinuation<Void, Never>?
    private let result: Result<QRLoginResponse, QRLoginError>

    init(_ result: Result<QRLoginResponse, QRLoginError>) {
        self.result = result
    }

    func holdNext() { hold = true }
    var isHeld: Bool { gate != nil }
    func release() {
        gate?.resume()
        gate = nil
    }

    func redeem(origin: URL, code: String) async throws -> QRLoginResponse {
        origins.append(origin)
        if hold {
            hold = false
            await withCheckedContinuation { gate = $0 }
        }
        return try result.get()
    }
}

extension AppState {
    convenience init(api: MockHestiaAPI,
                     receiptPairing: ReceiptPairing? = nil,
                     sessionStore: CredentialSessionStore? = nil,
                     events: @escaping @Sendable () -> AsyncStream<EventStream.Event> = { AsyncStream { $0.finish() } },
                     eventRetryDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let urlStore = BackendURLStore(userDefaults: UserDefaults(suiteName: "AppStateTests.\(UUID())")!)
        if let origin = receiptPairing?.server, origin != AppConfig.serverURL {
            urlStore.saveOverride(origin)
        } else if BackendURLStore.shared.hasOverride() {
            urlStore.saveOverride(AppConfig.serverURL)
        }
        self.init(api: api, receiptPairing: receiptPairing ?? ReceiptPairing(store: MemoryDeviceTokenStore()),
                  sessionStore: sessionStore ?? CredentialSessionStore(backendURLStore: urlStore, keychain: TestSessionKeychain()),
                  events: { _ in events() }, eventRetryDelay: eventRetryDelay)
    }
}

private final class RecordedEvents: Sendable {
    private struct State {
        var starts = 0
        var streams: [Int: AsyncStream<EventStream.Event>.Continuation] = [:]
    }

    private let state = Mutex(State())
    var starts: Int { state.withLock { $0.starts } }
    func isOpen(_ id: Int) -> Bool { state.withLock { $0.streams[id] != nil } }

    func open() -> AsyncStream<EventStream.Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: EventStream.Event.self)
        let id = state.withLock {
            $0.starts += 1
            let id = $0.starts
            $0.streams[id] = continuation
            return id
        }
        continuation.onTermination = { [weak self] _ in self?.closed(id) }
        return stream
    }

    func send(_ event: EventStream.Event, to id: Int = 1) {
        let continuation = state.withLock { $0.streams[id] }
        continuation?.yield(event)
    }

    private func closed(_ id: Int) { state.withLock { _ = $0.streams.removeValue(forKey: id) } }
}

private actor EventRetryGate {
    private(set) var delays: [Duration] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var finished = false

    func wait(_ delay: Duration) async throws {
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        delays.append(delay)
        await withCheckedContinuation { gate = $0 }
        try Task.checkCancellation()
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func finish() {
        finished = true
        release()
    }
}

private actor RecordingPairingAPI: DevicePairingAPI {
    struct Revocation: Equatable {
        let token: ReceiptDeviceToken
        let origin: URL
    }

    private(set) var revocations: [Revocation] = []
    private let revokeError: URLError?

    init(revokeError: URLError? = URLError(.notConnectedToInternet)) {
        self.revokeError = revokeError
    }

    func login(username: String, password: String, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        throw DevicePairingError.redeemFailed
    }

    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        fakeDeviceToken
    }

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        revocations.append(.init(token: token, origin: server))
        if let revokeError { throw revokeError }
    }
}

@MainActor
final class AppStateTests: XCTestCase {

    /// An event source that connects to nothing and finishes immediately, so tests
    /// that exercise login/connect don't reach the real network.
    private static let noEvents: @Sendable () -> AsyncStream<EventStream.Event> = {
        AsyncStream { $0.finish() }
    }

    /// An event source that connects and stays open without delivering, so the
    /// event loop parks in its `for await` (no reconnect spin) until cancelled.
    private static let openForever: @Sendable () -> AsyncStream<EventStream.Event> = {
        AsyncStream { _ in }
    }

    /// Poll the main actor until `cond` holds (or a timeout), letting background
    /// tasks (the event loop) make progress between checks.
    private func until(_ cond: @escaping () -> Bool, timeout: TimeInterval = 2) async {
        let start = Date()
        while !cond() && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Wait until the mock has recorded at least `n` discovery (snapshot) calls.
    private func discoveries(_ mock: MockHestiaAPI, atLeast n: Int, timeout: TimeInterval = 2) async -> Int {
        let start = Date()
        var count = await mock.calls.filter { $0 == .discovery }.count
        while count < n && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 5_000_000)
            count = await mock.calls.filter { $0 == .discovery }.count
        }
        return count
    }

    private func device(_ id: String, type: String, on: Bool? = nil, setpoint: Double? = nil) -> IdentifiedDevice {
        IdentifiedDevice(id: id, device: .init(setpoint: setpoint, _switch: on, _type: type))
    }

    private func makeDiscovery(_ devices: [String: Components.Schemas.DeviceInfo]) -> Components.Schemas.Discovery {
        .init(
            devices: .init(additionalProperties: devices),
            globals: .init(cribTemp: 21, outdoorHumidity: 50, outdoorTemp: 10),
            irButtons: [],
            klima: .init(file: "k.ir", powerOn: .init(additionalProperties: ["cool": [18, 19, 20]]), presets: ["off"]),
            klimaState: .init(mode: "cool", power: false, temp: 20),
            mode: "standalone",
            ruleVocab: .init(cmpOps: [], conditionTypes: [], frameActionOps: [], modes: [],
                             presenceEvents: [], stateFields: .init(), sunEvents: [], triggerTypes: []),
            summary: .init(confirmed: 0, total: devices.count, unknown: 0),
            targetMode: "standalone"
        )
    }

    private func connectAndWaitForEventSnapshot(_ app: AppState, mock: MockHestiaAPI) async {
        await app.connect()
        _ = await discoveries(mock, atLeast: 2)
    }

    func testLoadDiscoveryPopulatesState() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "1": .init(_switch: true, _type: "light"),
            "2": .init(_type: "blind"),
            "3": .init(setpoint: 20, thermostatOn: true, _type: "thermostat"),
        ]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.rooms.isEmpty)
        XCTAssertNotNil(app.klima)
        XCTAssertTrue(app.hasLights)
        XCTAssertTrue(app.hasBlinds)
    }

    func testSignOutDuringDiscoveryPublishesNothing() async throws {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        let app = AppState(api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()), events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        await mock.setHoldDiscovery()

        let load = Task { await app.loadDiscovery() }
        try await waitUntil("the held discovery") { await mock.isDiscoveryHeld }
        await app.signOut()
        await mock.releaseDiscovery()
        _ = await load.value

        XCTAssertTrue(app.rooms.isEmpty)
        XCTAssertNil(app.summary)
        XCTAssertEqual(app.phase, .needsAuth)
    }

    func testLoginFailureAfterSignOutKeepsSignedOutPhase() async throws {
        let mock = MockHestiaAPI()
        await mock.setHoldLogin()
        await mock.setLoginError(.serverNotFound)
        let app = AppState(api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()), events: Self.noEvents)

        let login = Task { await app.login(user: "u", password: "fake-password") }
        try await waitUntil("the held login") { !(await mock.calls.isEmpty) }
        await app.signOut()
        await mock.releaseLogin()
        await login.value

        XCTAssertEqual(app.phase, .needsAuth)
    }

    func testSupersededPasswordLoginCannotReplaceCommittedSession() async throws {
        let defaults = UserDefaults(suiteName: "AppStateTests.\(UUID())")!
        let keychain = TestSessionKeychain()
        let store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        let mock = MockHestiaAPI()
        await mock.setCapabilities(Capabilities(user: "second"))
        await mock.setHoldLogin()
        let app = AppState(api: mock, sessionStore: store, events: Self.noEvents)

        let first = Task { await app.login(user: "first", password: "fake-password") }
        try await waitUntil("the first login request") { await mock.count(.login("first", "fake-password")) == 1 }
        await app.login(user: "second", password: "fake-password")
        await mock.releaseLogin()
        await first.value

        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(store.currentSnapshot()?.actor, "second")
        XCTAssertEqual(keychain.mutations, [.write(.authoritative)])
    }

    func testLoginWaitsForTheBackendChangeLogout() async throws {
        let origin = URL(string: "https://hestia.example")!
        let store = CredentialSessionStore(
            backendURLStore: BackendURLStore(userDefaults: UserDefaults(suiteName: "AppStateTests.\(UUID())")!),
            keychain: TestSessionKeychain()
        )
        try store.commitAuthoritative(origin: origin, actor: "u", token: "old-token")
        let mock = MockHestiaAPI()
        await mock.setHoldLogout()
        let app = AppState(api: mock, sessionStore: store, events: Self.noEvents)

        XCTAssertTrue(app.saveAndConnect(origin.absoluteString))
        XCTAssertEqual(app.phase, .connecting)
        let login = Task { await app.login(user: "u", password: "fake-password") }
        try await waitUntil("the held logout") { await mock.isLogoutHeld }
        await mock.releaseLogout()
        await login.value

        let finishedAtLogin = await mock.logoutsFinishedAtLogin
        XCTAssertEqual(finishedAtLogin, 1, "login must start only after the backend change's logout finished")
    }

    func testSignOutWhileLoginWaitsForBackendChangeCancelsIt() async throws {
        let store = BackendURLStore.shared
        let previous = store.hasOverride() ? store.currentEffectiveURL() : nil
        defer { if let previous { store.saveOverride(previous) } else { store.clearOverride() } }

        let mock = MockHestiaAPI()
        await mock.setHoldDiscovery()
        let app = AppState(api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()), events: Self.noEvents)

        XCTAssertTrue(app.saveAndConnect(AppConfig.serverURL.absoluteString))
        try await waitUntil("the reset's discovery") { await mock.isDiscoveryHeld }
        let login = Task { await app.login(user: "u", password: "fake-password") }
        await Task.yield()
        await app.signOut()
        await mock.releaseDiscovery()
        await login.value

        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.login("u", "fake-password")))
        XCTAssertEqual(app.phase, .needsAuth)
    }

    /// Whole-home sweeps go through the server scene endpoint — exactly one call,
    /// no per-device fan-out (the server owns the exclusion list), then a refetch.
    /// The home is populated (incl. a 2-gang light) so any reintroduced client-side
    /// sweep would surface as setSwitch/setCover calls and fail the exact match.
    func testAllLightsRunsServerScene() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "1": .init(_switch: true, _type: "light"),
            "7": .init(endpointNames: .init(additionalProperties: ["1": "duże", "2": "małe"]),
                       endpoints: .init(additionalProperties: ["1": true, "2": false]),
                       _switch: true, _type: "light"),    // 2-gang
            "2": .init(_type: "blind"),
        ]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        let before = await mock.calls.count
        await app.allLights(on: true)
        await app.allLights(on: false)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls[before...]), [.scene(.lightsOn, nil), .discovery, .scene(.lightsOff, nil), .discovery])
    }

    func testToggleGangSendsEndpoint() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.toggle(device("7", type: "light"), on: false, endpoint: 2)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(7, false, 2)))
    }

    func testAllBlindsRunsServerScene() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "2": .init(_type: "blind"),
            "3": .init(_type: "blind"),
            "1": .init(_switch: true, _type: "light"),
        ]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        let before = await mock.calls.count
        await app.allBlinds(up: true)
        await app.allBlinds(up: false)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls[before...]), [.scene(.blindsUp, nil), .discovery, .scene(.blindsDown, nil), .discovery])
    }

    /// The whole-home slider is a single server scene carrying the wire position
    /// (display % run through the perceptual curve), never a per-device fan-out.
    func testSetAllBlindsRunsServerSceneWithWireValue() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "2": .init(_type: "blind"),
            "3": .init(_type: "blind"),
        ]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        let before = await mock.calls.count
        await app.setAllBlinds(percent: 50)          // curve: display 50 % → wire 64
        let calls = await mock.calls
        XCTAssertEqual(Array(calls[before...]), [.scene(.blindsSet, 64), .discovery])
    }

    /// The slider's live position is the mean displayed openness across blinds that
    /// report a wire level (curved), so it agrees with the per-room sliders.
    func testAverageBlindPercentIsCurvedMean() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "2": .init(level: 64, _type: "blind"),   // → 50 %
            "3": .init(level: 99, _type: "blind"),   // → 100 %
            "1": .init(_switch: true, _type: "light"),
        ]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        XCTAssertEqual(app.averageBlindPercent, 75)  // mean(50, 100)
    }

    /// No blind reports a position yet → nil, so the UI shows a dash rather than a
    /// fabricated "50 %" (the slider still parks its handle at a neutral 50).
    func testAverageBlindPercentIsNilWhenNoLevels() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        XCTAssertNil(app.averageBlindPercent)
    }

    func testSceneFailureSetsFailedPhase() async {
        let mock = MockHestiaAPI()
        await mock.setSceneError(.http(503))
        let app = AppState(api: mock)
        await app.allLights(on: true)
        XCTAssertEqual(app.phase, .failed(.http(503)))
        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.discovery))   // failed scene → no refetch
    }

    func testKlimaSetSendsIR() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        let app = AppState(api: mock, events: Self.openForever)
        defer { app.enterBackground() }
        await connectAndWaitForEventSnapshot(app, mock: mock)
        await app.klimaSet(mode: "cool", temp: 20)
        await app.klimaOff()
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.sendIR("k.ir", "on_cool_20")))
        XCTAssertTrue(calls.contains(.sendIR("k.ir", "off")))
    }

    func testBootstrapUnconfiguredWhenNoOverride() async {
        BackendURLStore.shared.clearOverride()
        let app = AppState(api: MockHestiaAPI())
        await app.bootstrap()
        XCTAssertEqual(app.phase, .unconfigured)
    }

    func testRoomGroupGroupsByRoom() {
        let discovery = makeDiscovery([
            "1": .init(name: "Lamp", room: "Salon", _type: "light"),
            "2": .init(room: "Salon", _type: "blind"),
            "9": .init(room: "Kitchen", _type: "thermostat"),
        ])
        let groups = RoomGroup.group(discovery)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.name).sorted(), ["Kitchen", "Salon"])
    }

    func testToggleSendsSwitch() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.toggle(device("4", type: "light"), on: true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(4, true, nil)))
    }

    func testSetCoverMapsPercentToValue() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setCover(device("5", type: "blind"), percent: 100)
        await app.setCover(device("5", type: "blind"), percent: 0)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setCover(5, 99)))
        XCTAssertTrue(calls.contains(.setCover(5, 0)))
    }

    func testSetThermostatPowersOnThenSets() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostat(device("9", type: "thermostat"), celsius: 22)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(2)), [.setThermostatPower(9, true), .setThermostat(9, 22)])
    }

    func testThermostatOffGoesTo4ThenOff() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostatPower(device("9", type: "thermostat"), on: false)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(2)), [.setThermostat(9, 4), .setThermostatPower(9, false)])
    }

    func testThermostatOnJustPowersOn() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostatPower(device("9", type: "thermostat"), on: true)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(1)), [.setThermostatPower(9, true)])
    }

    func testLoginSetsIdentity() async {
        let mock = MockHestiaAPI()
        await mock.setWhoami(role: "operator")
        let app = AppState(api: mock, events: Self.noEvents)
        await app.login(user: "alice", password: "pw")
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.login("alice", "pw")))
        XCTAssertEqual(app.whoami?.user, "u")
        XCTAssertFalse(app.isReadOnly)
    }

    func testViewerIsReadOnly() async {
        let mock = MockHestiaAPI()
        await mock.setWhoami(role: "viewer")
        let app = AppState(api: mock, events: Self.noEvents)
        await app.login(user: "v", password: "pw")
        XCTAssertTrue(app.isReadOnly)
    }

    func testLiveEventSnapshotsAndHighlights() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["7": .init(_switch: true, _type: "light")]))
        let (stream, cont) = AsyncStream.makeStream(of: EventStream.Event.self)
        let app = AppState(api: mock, events: { stream })
        await app.login(user: "u", password: "pw")     // starts the event loop

        cont.yield(.connected)                          // → catch-up snapshot
        cont.yield(.change(node: 7))                     // → highlight node 7 + snapshot
        await until { app.recentlyChanged.contains("7") }

        XCTAssertTrue(app.recentlyChanged.contains("7"))
        let discoveries = await mock.calls.filter { $0 == .discovery }.count
        XCTAssertGreaterThanOrEqual(discoveries, 2)      // login snapshot + ≥1 event-driven snapshot

        cont.finish()
        await app.signOut()                              // stop the event loop
    }

    func testForegroundResyncsSnapshot() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        let app = AppState(api: mock, events: Self.openForever)
        await app.login(user: "u", password: "pw")        // .ready; event loop snapshots once
        let before = await discoveries(mock, atLeast: 2)    // login snapshot + event-loop snapshot

        app.enterForeground()                               // → reconnect + fresh snapshot
        let after = await discoveries(mock, atLeast: before + 1)
        XCTAssertGreaterThan(after, before)

        app.enterBackground()                               // stops cleanly (no assertion needed)
    }

    private func makeApp(mock: MockHestiaAPI, events: RecordedEvents, retry: EventRetryGate? = nil) -> AppState {
        AppState(api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()), events: events.open,
                 eventRetryDelay: { delay in
                     if let retry { try await retry.wait(delay) } else { try await Task.sleep(for: delay) }
                 })
    }

    private func connectLive(_ app: AppState, mock: MockHestiaAPI, events: RecordedEvents) async throws {
        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        await app.connect()
        try await waitUntil("the live event stream") { events.isOpen(1) }
    }

    private func assertIOCCleared(_ app: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.rooms.isEmpty, file: file, line: line)
        XCTAssertNil(app.summary, file: file, line: line)
        XCTAssertNil(app.globals, file: file, line: line)
        XCTAssertNil(app.klima, file: file, line: line)
        XCTAssertNil(app.klimaState, file: file, line: line)
    }

    func testRepeatedDiscovery403ProducesZeroSSEStreamStartsAndClearsIOC() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        await mock.setDiscoveryError(APIError.forbidden)
        await mock.setHoldDiscovery()
        defer {
            app.enterBackground()
            Task { await mock.releaseDiscovery() }
        }

        let connect = Task { await app.connect() }
        try await waitUntil("the first discovery request") { await mock.isDiscoveryHeld }
        let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
        await mock.setCapabilities(viewer)
        await mock.releaseDiscovery()
        await connect.value
        try await waitUntil("the first denial refresh publication") { app.capabilities == viewer }

        await app.refresh()
        try await waitUntil("the second denial refresh") { await mock.count(.capabilities) == 4 }

        let snapshots = await mock.count(.discovery)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(events.starts, 0)
        XCTAssertNil(app.eventTask)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
        assertIOCCleared(app)
    }

    func testPostReadyDiscovery403StopsExistingSSEAndClearsIOC() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        await mock.setWhoami(role: "admin")
        try await connectLive(app, mock: mock, events: events)
        await mock.setDiscoveryError(APIError.forbidden)
        await mock.setHoldDiscovery()
        defer {
            app.enterBackground()
            Task { await mock.releaseDiscovery() }
        }

        let discovery = Task { await app.loadDiscovery() }
        try await waitUntil("the post-ready discovery request") { await mock.isDiscoveryHeld }
        XCTAssertFalse(app.rooms.isEmpty)
        XCTAssertTrue(events.isOpen(1))
        await mock.releaseDiscovery()
        let outcome = await discovery.value
        try await waitUntil("the denied stream to close") { !events.isOpen(1) }
        try await waitUntil("a denial refresh") { await mock.count(.capabilities) == 2 }

        XCTAssertEqual(outcome, .denied)
        XCTAssertEqual(events.starts, 1)
        XCTAssertNil(app.eventTask)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
        XCTAssertNotNil(app.receiptsAPI)
        assertIOCCleared(app)
    }

    func testCapabilityRefreshLossOfIOCViewStopsSSEAndClearsIOC() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        defer { app.enterBackground() }
        try await connectLive(app, mock: mock, events: events)
        let noIOC = Capabilities(user: "u", installation: [.calendarView])
        await mock.setCapabilities(noIOC)

        app.enterForeground()
        try await waitUntil("the foreground capability publication and stream closure") {
            app.capabilities == noIOC && !events.isOpen(1)
        }

        let snapshots = await mock.count(.discovery)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(events.starts, 1)
        XCTAssertNil(app.eventTask)
        XCTAssertFalse(app.canViewIOC)
        XCTAssertEqual(app.phase, .ready)
        assertIOCCleared(app)
    }

    func testLiveStreamFollowedByUserPullWithdrawingIOCGrantCancelsSSEAndClearsIOC() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        try await connectLive(app, mock: mock, events: events)
        let noIOC = Capabilities(user: "u")
        await mock.setCapabilities(noIOC)
        await mock.setHoldCapabilities()
        defer {
            app.enterBackground()
            Task { await mock.releaseCapabilities() }
        }

        let refresh = Task { await app.refresh() }
        try await waitUntil("the pull's capability request") { await mock.isCapabilitiesHeld }
        XCTAssertTrue(events.isOpen(1))
        XCTAssertFalse(app.rooms.isEmpty)
        await mock.releaseCapabilities()
        await refresh.value
        try await waitUntil("the withdrawn stream to close") { !events.isOpen(1) }

        let snapshots = await mock.count(.discovery)
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(events.starts, 1)
        XCTAssertNil(app.eventTask)
        XCTAssertEqual(app.capabilities, noIOC)
        XCTAssertEqual(app.phase, .ready)
        assertIOCCleared(app)
    }

    func testDiscoveryTransientFailureBacksOffWithoutStreamWhile401Or403OrCancelStopsLoop() async throws {
        let stoppedOutcomes: [(any Error, AppState.Phase, APIError?)] = [
            (APIError.unauthorized, .needsAuth, nil),
            (APIError.forbidden, .ready, .forbidden),
            (CancellationError(), .ready, nil),
        ]
        for (terminalError, expectedPhase, expectedNotice) in stoppedOutcomes {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let retry = EventRetryGate()
            let app = makeApp(mock: mock, events: events, retry: retry)
            defer {
                app.enterBackground()
                Task { await retry.finish() }
            }
            try await connectLive(app, mock: mock, events: events)
            app.enterBackground()
            await mock.setDiscoveryError(APIError.http(503))

            app.enterForeground()
            try await waitUntil("the HTTP failure's backoff") { await retry.delays.count == 1 }
            XCTAssertEqual(events.starts, 1)
            XCTAssertNotNil(app.eventTask)

            await mock.setDiscoveryError(URLError(.networkConnectionLost))
            await retry.release()
            try await waitUntil("the transport failure's backoff") { await retry.delays.count == 2 }
            XCTAssertEqual(events.starts, 1)
            XCTAssertEqual(app.phase, .ready)

            await mock.setDiscoveryError(terminalError)
            await retry.release()
            try await waitUntil("discovery to stop after \(terminalError)") { app.eventTask == nil }

            let delays = await retry.delays
            let snapshots = await mock.count(.discovery)
            XCTAssertEqual(delays, [.seconds(1), .seconds(2)])
            XCTAssertEqual(snapshots, 5)
            XCTAssertEqual(events.starts, 1)
            XCTAssertEqual(app.phase, expectedPhase)
            XCTAssertEqual(app.notice, expectedNotice)
        }
    }

    func testInitialConnectCapabilities403FailsAndFirstDiscovery403TransitionsToReady() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        defer { app.enterBackground() }
        await mock.setCapabilitiesError(.forbidden)

        await app.connect()

        let snapshotsAfterCapabilityDenial = await mock.count(.discovery)
        XCTAssertEqual(snapshotsAfterCapabilityDenial, 0)
        XCTAssertEqual(app.phase, .failed(.forbidden))
        XCTAssertNil(app.capabilities)
        XCTAssertNil(app.receiptsAPI)

        await mock.setWhoami(role: "admin")
        await mock.setDiscoveryError(APIError.forbidden)
        await app.connect()
        try await waitUntil("a denial refresh after initial discovery") { await mock.count(.capabilities) == 3 }

        let snapshots = await mock.count(.discovery)
        XCTAssertEqual(snapshots, 1)
        XCTAssertEqual(events.starts, 0)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
        XCTAssertNotNil(app.receiptsAPI)

        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        await app.refresh()
        try await waitUntil("SSE after the successful pull") { events.isOpen(1) }
        let before = await mock.calls.count
        await mock.setCapabilitiesError(.forbidden)

        await app.refresh()
        try await waitUntil("the capability denial to close the stream") { !events.isOpen(1) }

        let calls = await mock.calls
        XCTAssertEqual(Array(calls[before...]), [.capabilities])
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
        XCTAssertNil(app.capabilities)
        XCTAssertNil(app.receiptsAPI)
        XCTAssertNil(app.eventTask)
        assertIOCCleared(app)
    }

    func testCapabilityUnauthorizedClearsSessionDuringConnectAndSignedInRefresh() async throws {
        for signedIn in [false, true] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer { app.enterBackground() }
            if signedIn {
                await mock.setWhoami(role: "admin")
                try await connectLive(app, mock: mock, events: events)
                XCTAssertNotNil(app.receiptsAPI)
            }
            let before = await mock.calls.count
            await mock.setCapabilitiesError(.unauthorized)

            if signedIn {
                await app.refresh()
            } else {
                await app.connect()
            }
            try await waitUntil("the event stream to close") { !events.isOpen(1) }

            let calls = await mock.calls
            XCTAssertEqual(Array(calls[before...]), [.capabilities])
            XCTAssertEqual(app.phase, .needsAuth)
            XCTAssertNil(app.capabilities)
            XCTAssertNil(app.whoami)
            XCTAssertNil(app.receiptsAPI)
            XCTAssertNil(app.notice)
            XCTAssertNil(app.eventTask)
            assertIOCCleared(app)
        }
    }

    func testPullToRefreshWithUnchangedGrantReloadsDiscoveryAndRestartsMissingStream() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        defer { app.enterBackground() }
        try await connectLive(app, mock: mock, events: events)
        let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
        await mock.setCapabilities(viewer)
        events.send(.forbidden)
        try await waitUntil("SSE denial and capability publication") { app.eventTask == nil && app.capabilities == viewer }
        assertIOCCleared(app)

        await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
        await mock.setHoldDiscovery()
        defer { Task { await mock.releaseDiscovery() } }
        let refresh = Task { await app.refresh() }
        try await waitUntil("the pull's snapshot") { await mock.isDiscoveryHeld }
        XCTAssertEqual(events.starts, 1)
        await mock.releaseDiscovery()
        await refresh.value
        try await waitUntil("SSE restart after the snapshot") { events.isOpen(2) }

        let snapshots = await mock.count(.discovery)
        let capabilityRequests = await mock.count(.capabilities)
        XCTAssertEqual(snapshots, 3)
        XCTAssertEqual(capabilityRequests, 3)
        XCTAssertEqual(app.capabilities, viewer)
        XCTAssertEqual(app.rooms.flatMap(\.devices).map(\.id), ["2"])

        let updatedGrant = Capabilities.fromLegacyRole(role: "operator", user: "u")
        await mock.setCapabilities(updatedGrant)
        // The replacement socket is still waiting for its HTTP response.
        await app.refresh()
        try await waitUntil("the pending SSE handshake to be replaced") { !events.isOpen(2) && events.isOpen(3) }

        let snapshotsAfterGrantChange = await mock.count(.discovery)
        XCTAssertEqual(snapshotsAfterGrantChange, 4)
        XCTAssertEqual(events.starts, 3)
        XCTAssertEqual(app.capabilities, updatedGrant)
    }

    func testDenialTriggeredRefreshDoesNotImmediatelyReopenDiscoveryOrSSE() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let app = makeApp(mock: mock, events: events)
        defer {
            app.enterBackground()
            Task { await mock.releaseCapabilities() }
        }
        await mock.setWhoami(role: "admin")
        try await connectLive(app, mock: mock, events: events)
        let afterStreamDenial = Capabilities.fromLegacyRole(role: "admin", user: "current")
        await mock.setCapabilities(afterStreamDenial)
        events.send(.forbidden)
        try await waitUntil("the foreground stream to stop and its denial refresh to finish") {
            app.eventTask == nil && app.capabilities == afterStreamDenial
        }
        let updated = Capabilities.fromLegacyRole(role: "admin", user: "updated")
        await mock.setCapabilities(updated)
        await mock.setHoldCapabilities()
        await mock.setSceneError(.forbidden)

        let before = await mock.calls.count
        let receipts = try XCTUnwrap(app.receiptsAPI)
        do {
            _ = try await receipts.parseReceiptText("receipt", source: .paste)
            XCTFail("Expected the receipt authorization error")
        } catch let error as ReceiptError {
            XCTAssertEqual(error, .forbidden)
        }
        try await waitUntil("the receipt denial's capability refresh") { await mock.isCapabilitiesHeld }
        await app.allLights(on: true)
        await mock.releaseCapabilities()
        try await waitUntil("the shared denial refresh publication") { app.capabilities == updated }

        let calls = await mock.calls
        XCTAssertEqual(Array(calls[before...]), [.parseReceipt, .capabilities, .scene(.lightsOn, nil)])
        XCTAssertEqual(events.starts, 1)
        XCTAssertNil(app.eventTask)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
    }

    func testSSEDenialsAfterCapabilityChangeStillApplyToLiveStream() async throws {
        for event: EventStream.Event in [.unauthorized, .forbidden] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer { app.enterBackground() }
            try await connectLive(app, mock: mock, events: events)
            events.send(.connected)
            await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
            events.send(.change(node: nil))
            try await waitUntil("the connected stream's snapshot") {
                app.rooms.flatMap(\.devices).map(\.id) == ["2"]
            }

            let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
            await mock.setCapabilities(viewer)
            await app.refresh()
            XCTAssertEqual(app.capabilities, viewer)
            XCTAssertTrue(app.canViewIOC)
            XCTAssertTrue(events.isOpen(1))
            XCTAssertEqual(events.starts, 1)

            events.send(event)
            try await waitUntil("the live stream to stop after the denial") { app.eventTask == nil }
            switch event {
            case .unauthorized:
                XCTAssertEqual(app.phase, .needsAuth)
                XCTAssertNil(app.capabilities)
                let logouts = await mock.count(.logout)
                XCTAssertEqual(logouts, 0)
            case .forbidden:
                XCTAssertEqual(app.phase, .ready)
                XCTAssertEqual(app.notice, .forbidden)
                try await waitUntil("the SSE denial's capability refresh") { await mock.count(.capabilities) == 3 }
            default:
                XCTFail("Expected an SSE authorization error")
            }
            assertIOCCleared(app)
            XCTAssertEqual(events.starts, 1)
        }
    }

    func testDenialCapabilityUpdatePreservesInFlightDiscoveryAndEventStream() async throws {
        for resuming in [false, true] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer {
                app.enterBackground()
                Task { await mock.releaseDiscovery() }
            }
            try await connectLive(app, mock: mock, events: events)
            events.send(.connected)
            await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
            await mock.setHoldDiscovery()
            if resuming {
                app.enterForeground()
            } else {
                events.send(.change(node: nil))
            }
            try await waitUntil("the event loop's discovery request") { await mock.isDiscoveryHeld }

            let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
            await mock.setCapabilities(viewer)
            await mock.setSceneError(.forbidden)
            await app.allLights(on: false)
            try await waitUntil("the denial refresh to update capabilities") { app.capabilities == viewer }
            XCTAssertTrue(app.canViewIOC)
            await mock.releaseDiscovery()

            let streamID = resuming ? 2 : 1
            try await waitUntil("discovery to publish and the stream to stay open") {
                app.rooms.flatMap(\.devices).map(\.id) == ["2"] && events.isOpen(streamID)
            }
            XCTAssertNotNil(app.eventTask)
            XCTAssertEqual(events.starts, streamID)
            XCTAssertEqual(app.notice, .forbidden)
            let snapshots = await mock.count(.discovery)
            XCTAssertEqual(snapshots, 3)
        }
    }

    func testSuccessfulExplicitRefreshClearsDenialNoticeWithoutIOCGrant() async throws {
        for foreground in [false, true] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer { app.enterBackground() }
            let grant = Capabilities(delegatedReceipts: .init(permissions: [.budgetReceiptsAdd], canUse: true))
            let changed = Capabilities(delegatedReceipts: .init(
                permissions: [.budgetReceiptsAdd, .budgetReceiptsMatch], canUse: true
            ))
            await mock.setCapabilities(grant)
            await app.connect()
            let receipts = try XCTUnwrap(app.receiptsAPI)
            await mock.setCapabilities(changed)
            do {
                _ = try await receipts.parseReceiptText("receipt", source: .paste)
                XCTFail("Expected a receipt denial")
            } catch let error as ReceiptError {
                XCTAssertEqual(error, .forbidden)
            }
            try await waitUntil("the receipt denial's refresh") { app.capabilities == changed }
            XCTAssertEqual(app.notice, .forbidden)

            await mock.setCapabilities(grant)
            if foreground {
                app.enterForeground()
                try await waitUntil("the foreground refresh to clear the denial notice") {
                    app.capabilities == grant && app.notice == nil
                }
            } else {
                await app.refresh()
            }

            XCTAssertEqual(app.capabilities, grant)
            XCTAssertNil(app.notice)
            XCTAssertFalse(app.canViewIOC)
            XCTAssertNotNil(app.receiptsAPI)
            XCTAssertEqual(events.starts, 0)
            let snapshots = await mock.count(.discovery)
            XCTAssertEqual(snapshots, 0)
        }
    }

    func testDenialSupersedesHeldExplicitCapabilityRefresh() async throws {
        for foreground in [false, true] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer {
                app.enterBackground()
                Task { await mock.releaseCapabilities() }
            }
            try await connectLive(app, mock: mock, events: events)
            await mock.setCapabilitiesError(.unauthorized)
            await mock.setHoldCapabilities()
            let pull: Task<Void, Never>?
            if foreground {
                pull = nil
                app.enterForeground()
            } else {
                pull = Task { await app.refresh() }
            }
            try await waitUntil("the older explicit capability request") { await mock.isCapabilitiesHeld }

            let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
            await mock.setCapabilities(viewer)
            await mock.setSceneError(.forbidden)
            await app.allLights(on: false)
            try await waitUntil("the fresh denial request to publish while the older request is held") {
                app.capabilities == viewer
            }
            XCTAssertEqual(app.notice, .forbidden)
            XCTAssertTrue(events.isOpen(1))
            await mock.releaseCapabilities()
            await pull?.value

            let queries = await mock.count(.capabilities)
            let logouts = await mock.count(.logout)
            XCTAssertEqual(queries, 3)
            XCTAssertEqual(logouts, 0)
            XCTAssertEqual(app.phase, .ready)
            XCTAssertEqual(app.capabilities, viewer)
        }
    }

    func testExplicitCapabilityRefreshSupersedesHeldDenialRefresh() async throws {
        for foreground in [false, true] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let app = makeApp(mock: mock, events: events)
            defer {
                app.enterBackground()
                Task { await mock.releaseCapabilities() }
            }
            try await connectLive(app, mock: mock, events: events)
            await mock.setCapabilities(.init())
            await mock.setHoldCapabilities()
            await mock.setSceneError(.forbidden)
            await app.allLights(on: false)
            try await waitUntil("the older denial capability request") { await mock.isCapabilitiesHeld }

            let viewer = Capabilities.fromLegacyRole(role: "viewer", user: "u")
            await mock.setCapabilities(viewer)
            let pull: Task<Void, Never>?
            if foreground {
                pull = nil
                app.enterForeground()
            } else {
                pull = Task { await app.refresh() }
            }
            try await waitUntil("the explicit refresh replacing the older denial") {
                app.capabilities == viewer && events.isOpen(2)
            }
            await pull?.value
            await mock.releaseCapabilities()

            let queries = await mock.count(.capabilities)
            XCTAssertEqual(queries, 3)
            XCTAssertEqual(app.phase, .ready)
            XCTAssertNil(app.notice)
            XCTAssertEqual(app.capabilities, viewer)
        }
    }

    func testPullToRefreshReplacesSSEWaitingInBackoff() async throws {
        let mock = MockHestiaAPI()
        let events = RecordedEvents()
        let retry = EventRetryGate()
        let app = makeApp(mock: mock, events: events, retry: retry)
        defer {
            app.enterBackground()
            Task { await retry.finish() }
        }
        try await connectLive(app, mock: mock, events: events)
        let waitingTask = try XCTUnwrap(app.eventTask)
        await mock.setDiscoveryError(APIError.http(503))
        events.send(.change(node: nil))
        try await waitUntil("the failed snapshot's retry delay") { await retry.delays.count == 1 }
        XCTAssertNotNil(app.eventTask)
        XCTAssertEqual(events.starts, 1)

        await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
        await app.refresh()
        try await waitUntil("SSE to reopen before the held backoff ends") { events.isOpen(2) }
        await retry.release()
        await waitingTask.value

        XCTAssertTrue(events.isOpen(2))
        XCTAssertEqual(events.starts, 2)
        XCTAssertEqual(app.rooms.flatMap(\.devices).map(\.id), ["2"])
        let snapshots = await mock.count(.discovery)
        let delays = await retry.delays
        XCTAssertEqual(snapshots, 4)
        XCTAssertEqual(delays, [.seconds(1)])
    }

    func testSSEDenial403StopsWithoutReconnectLoopAnd401LogsOut() async throws {
        for event: EventStream.Event in [.forbidden, .unauthorized] {
            let mock = MockHestiaAPI()
            let events = RecordedEvents()
            let retry = EventRetryGate()
            let app = makeApp(mock: mock, events: events, retry: retry)
            defer {
                app.enterBackground()
                Task { await retry.finish() }
            }
            await mock.setWhoami(role: "admin")
            try await connectLive(app, mock: mock, events: events)
            await app.refresh()
            XCTAssertTrue(events.isOpen(1))
            XCTAssertEqual(events.starts, 1)

            events.send(event)
            try await waitUntil("SSE termination after a status error") { app.eventTask == nil && !events.isOpen(1) }

            switch event {
            case .forbidden:
                try await waitUntil("the SSE denial refresh") { await mock.count(.capabilities) == 3 }
                XCTAssertEqual(app.phase, .ready)
                XCTAssertEqual(app.notice, .forbidden)
                XCTAssertNotNil(app.receiptsAPI)
            case .unauthorized:
                let logouts = await mock.count(.logout)
                XCTAssertEqual(logouts, 0)
                XCTAssertEqual(app.phase, .needsAuth)
                XCTAssertNil(app.capabilities)
                XCTAssertNil(app.receiptsAPI)
            default:
                XCTFail("Expected an SSE authorization error")
            }

            let delays = await retry.delays
            let snapshots = await mock.count(.discovery)
            XCTAssertEqual(delays, [])
            XCTAssertEqual(snapshots, 3)
            XCTAssertEqual(events.starts, 1)
            assertIOCCleared(app)
        }
    }

    func testPausedOldRequestLate401And403CannotMutateNewerSession() async throws {
        for error: APIError in [.unauthorized, .forbidden] {
            for request in PausedRequest.allCases {
                let mock = MockHestiaAPI()
                let events = RecordedEvents()
                let app = makeApp(mock: mock, events: events)
                try await connectLive(app, mock: mock, events: events)
                defer {
                    app.enterBackground()
                    Task { await request.release(on: mock) }
                }

                await request.hold(on: mock, error: error)
                let oldRequest = Task { await request.run(on: app) }
                try await waitUntil("the old \(request) request") { await request.isHeld(on: mock) }

                await app.signOut()
                let newGrant = Capabilities.fromLegacyRole(role: "viewer", user: "next")
                await mock.setCapabilities(newGrant)
                await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind")]))
                await app.connect()
                try await waitUntil("the new session's stream") { events.isOpen(2) }
                let calls = await mock.calls

                await request.release(on: mock)
                await oldRequest.value

                XCTAssertEqual(app.phase, .ready, "\(request) returned \(error)")
                XCTAssertEqual(app.capabilities, newGrant)
                XCTAssertNil(app.notice)
                XCTAssertEqual(app.rooms.flatMap(\.devices).map(\.id), ["2"])
                XCTAssertTrue(events.isOpen(2))
                let finalCalls = await mock.calls
                XCTAssertEqual(finalCalls, calls)
            }
        }
    }

    private enum PausedRequest: CaseIterable {
        case capabilities, discovery, scene

        func hold(on mock: MockHestiaAPI, error: APIError) async {
            switch self {
            case .capabilities:
                await mock.setCapabilitiesError(error)
                await mock.setHoldCapabilities()
            case .discovery:
                await mock.setDiscoveryError(error)
                await mock.setHoldDiscovery()
            case .scene:
                await mock.setSceneError(error)
                await mock.setHoldScene()
            }
        }

        func isHeld(on mock: MockHestiaAPI) async -> Bool {
            switch self {
            case .capabilities: await mock.isCapabilitiesHeld
            case .discovery: await mock.isDiscoveryHeld
            case .scene: await mock.isSceneHeld
            }
        }

        func release(on mock: MockHestiaAPI) async {
            switch self {
            case .capabilities: await mock.releaseCapabilities()
            case .discovery: await mock.releaseDiscovery()
            case .scene: await mock.releaseScene()
            }
        }

        @MainActor
        func run(on app: AppState) async {
            switch self {
            case .capabilities: await app.refresh()
            case .discovery: _ = await app.loadDiscovery()
            case .scene: await app.allLights(on: true)
            }
        }
    }

    func testForegroundIgnoredWhenNotReady() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock, events: Self.openForever)   // phase stays .connecting
        app.enterForeground()
        let calls = await mock.calls
        XCTAssertFalse(calls.contains(.discovery))          // no session → no snapshot/connect
    }

    func testSignOut() async throws {
        let origin = URL(string: "https://hestia.example")!
        let store = CredentialSessionStore(
            backendURLStore: BackendURLStore(userDefaults: UserDefaults(suiteName: "AppStateTests.\(UUID())")!),
            keychain: TestSessionKeychain()
        )
        try store.commitAuthoritative(origin: origin, actor: "u", token: "old-token")
        let mock = MockHestiaAPI()
        let app = AppState(api: mock, sessionStore: store, events: Self.noEvents)
        await app.signOut()
        let logoutCredentials = await mock.logoutCredentials
        XCTAssertEqual(logoutCredentials, [.init(origin: origin, actor: nil, token: "old-token")])
        XCTAssertNil(store.currentSnapshot())
        XCTAssertNil(app.whoami)
        XCTAssertEqual(app.phase, .needsAuth)
    }

    @MainActor
    private struct CodePairingFixture {
        let origin = URL(string: "https://hestia.example")!
        let keychain = TestSessionKeychain()
        let devices = MemoryDeviceTokenStore()
        let pairingAPI = RecordingPairingAPI(revokeError: nil)
        let mock = MockHestiaAPI()
        let store: CredentialSessionStore
        let oldSession: BoundSession
        let app: AppState

        init() async throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppStateTests.\(UUID())"))
            store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
            oldSession = try store.commitAuthoritative(origin: origin, actor: "owner", token: "old-session")
            let pairing = ReceiptPairing(api: pairingAPI, store: devices, serverURL: { [origin] in origin })
            app = AppState(api: mock, receiptPairing: pairing, sessionStore: store, events: AppStateTests.noEvents)
            await mock.setCapabilities(Self.capabilities(for: "owner"))
            await app.bootstrap()
            XCTAssertEqual(app.phase, .ready)
            try await pairing.pair(code: try XCTUnwrap(ReceiptPairingCode("ABCD2345")), deviceName: "iPhone")
            XCTAssertEqual(pairing.status, .paired)
            XCTAssertEqual(pairing.credential(for: origin)?.provenance, .legacyCodeRedeem)
        }

        private static func capabilities(for actor: String) -> Capabilities {
            Capabilities(user: actor, ownBudget: .init(permissions: [.budgetReceiptsAdd], canView: true,
                                                      canUseReceipts: true, canManageDevices: true))
        }

        func expireSession() async {
            await mock.setCapabilitiesError(.unauthorized)
            await app.refresh()

            XCTAssertEqual(app.phase, .needsAuth)
            XCTAssertNil(store.currentSnapshot())
            XCTAssertEqual(store.backendURLStore.currentEffectiveURL(), origin)
            XCTAssertNil(app.receiptPairing.credential(for: origin))
            let revocations = await pairingAPI.revocations
            XCTAssertTrue(revocations.isEmpty)
        }

        func signIn(actor: String = "owner") async {
            await mock.setCapabilities(Self.capabilities(for: actor))
            await app.login(user: actor, password: "fake-password")

            XCTAssertEqual(app.phase, .ready)
            XCTAssertEqual(store.currentSnapshot()?.actor, actor)
        }

        func assertCodePairingRetained() async throws {
            let replacement = try XCTUnwrap(store.currentSnapshot())
            let retained = try XCTUnwrap(app.receiptPairing.credential(for: origin))
            XCTAssertNotEqual(replacement.commitID, oldSession.commitID)
            XCTAssertEqual(retained.sessionCommitID, replacement.commitID)
            XCTAssertEqual(retained.provenance, .legacyCodeRedeem)
            XCTAssertEqual(retained.credential, fakeDeviceToken)
            XCTAssertEqual(app.receiptPairing.status, .paired)
            XCTAssertTrue(devices.pending.isEmpty)
            let revocations = await pairingAPI.revocations
            XCTAssertTrue(revocations.isEmpty)
        }
    }

    func testCapabilities401KeepsCodePairedDeviceForSameActor() async throws {
        let fixture = try await CodePairingFixture()
        await fixture.expireSession()
        XCTAssertNil(fixture.keychain.storedData(for: .authoritative))

        await fixture.signIn()

        try await fixture.assertCodePairingRetained()
    }

    func testCapabilities401RevokesCodePairedDeviceForDifferentActor() async throws {
        let fixture = try await CodePairingFixture()
        await fixture.expireSession()

        await fixture.signIn(actor: "other")

        XCTAssertNil(fixture.devices.load())
        try await waitUntil("the previous device revocation to finish") { fixture.devices.pending.isEmpty }
        let revocations = await fixture.pairingAPI.revocations
        XCTAssertEqual(revocations, [.init(token: fakeDeviceToken, origin: fixture.origin)])
    }

    func testCapabilities401RevokesCodePairedDeviceWhenChangingOrigin() async throws {
        let fixture = try await CodePairingFixture()
        await fixture.expireSession()

        let newOrigin = URL(string: "https://hestia.example:8443")!
        XCTAssertTrue(fixture.app.saveAndConnect(newOrigin.absoluteString))
        try await waitUntil("sign-in after changing origin") { fixture.app.phase == .needsAuth }
        await fixture.signIn()

        XCTAssertEqual(fixture.store.currentSnapshot()?.origin, newOrigin)
        XCTAssertNil(fixture.devices.load())
        XCTAssertTrue(fixture.devices.pending.isEmpty)
        let revocations = await fixture.pairingAPI.revocations
        XCTAssertEqual(revocations, [.init(token: fakeDeviceToken, origin: fixture.origin)])
    }

    func testCapabilities401RetriesCodeHandoffOnForegroundAfterKeychainUnlock() async throws {
        let fixture = try await CodePairingFixture()
        let paired = try XCTUnwrap(fixture.devices.load())
        fixture.keychain.setLocked(true)

        await fixture.expireSession()

        XCTAssertNotNil(fixture.keychain.storedData(for: .authoritative))
        XCTAssertEqual(fixture.devices.load(), paired)
        XCTAssertTrue(fixture.devices.pending.isEmpty)

        fixture.keychain.setLocked(false)
        fixture.app.enterForeground()

        XCTAssertNil(fixture.keychain.storedData(for: .authoritative))
        let oldCommitID = try XCTUnwrap(fixture.oldSession.commitID)
        XCTAssertEqual(fixture.devices.load()?.codeSessionHandoff,
                       .init(actor: "owner", previousCommitID: oldCommitID))
        await fixture.signIn()
        try await fixture.assertCodePairingRetained()
    }

    func testCapabilities401RetriesFailedCodeHandoffAtPasswordSignIn() async throws {
        let fixture = try await CodePairingFixture()
        let paired = try XCTUnwrap(fixture.devices.load())
        fixture.devices.failNextSave()

        await fixture.expireSession()

        XCTAssertNotNil(fixture.keychain.storedData(for: .authoritative))
        XCTAssertEqual(fixture.devices.load(), paired)
        XCTAssertTrue(fixture.devices.pending.isEmpty)

        await fixture.signIn()

        try await fixture.assertCodePairingRetained()
    }

    func testUpgradePreservesLegacySessionActiveDeviceAndPendingRevocations() async throws {
        let origin = URL(string: "https://hestia.example")!
        let previousOrigin = URL(string: "https://hestia.example:8443")!
        let defaults = UserDefaults(suiteName: "AppStateTests.\(UUID())")!
        defaults.set(origin.absoluteString, forKey: BackendURLStore.userDefaultsKey)
        let keychain = TestSessionKeychain()
        keychain.seed(Data("legacy-token".utf8), for: .legacy)
        let store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        let active = StoredReceiptDeviceToken(server: origin, credential: fakeDeviceToken)
        let pending = StoredReceiptDeviceToken(server: previousOrigin, credential: fakeDeviceToken)
        let deviceStore = MemoryDeviceTokenStore(active)
        try deviceStore.savePendingRevocations([pending])
        let pairingAPI = RecordingPairingAPI()
        let pairing = ReceiptPairing(api: pairingAPI, store: deviceStore, serverURL: { origin })
        let mock = MockHestiaAPI()
        await mock.setWhoami(role: "admin")
        await mock.setDiscovery(makeDiscovery([:]))
        let app = AppState(api: mock, receiptPairing: pairing, sessionStore: store, events: Self.openForever)
        defer { app.enterBackground() }

        await app.bootstrap()

        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.whoami?.user, "u")
        let session = try XCTUnwrap(store.currentSnapshot())
        XCTAssertEqual(session.origin, origin)
        XCTAssertEqual(session.token, "legacy-token")
        XCTAssertEqual(session.actor, "u")
        XCTAssertEqual(store.backendURLStore.loadOverrideRecord()?.sessionCommitID, session.commitID)
        XCTAssertNil(keychain.storedData(for: .legacy))
        XCTAssertNotNil(keychain.storedData(for: .legacyMigrated))
        let verification = await mock.legacyVerificationRequests
        XCTAssertEqual(verification, [.init(origin: origin, actor: nil, token: "legacy-token")])
        XCTAssertEqual(pairing.credential(for: origin, session: session)?.credential, active.credential)
        XCTAssertEqual(deviceStore.load()?.provenance, .legacyMigrated1x)
        XCTAssertNil(pairing.credential(for: previousOrigin, session: session))
        try await waitUntil("the saved revocation retry") { await pairingAPI.revocations.count == 1 }
        let revocations = await pairingAPI.revocations
        XCTAssertEqual(revocations, [.init(token: pending.credential, origin: previousOrigin)])
        XCTAssertEqual(deviceStore.pending, [pending])
    }

    func testLockedKeychainLaunchChangesNothingAndRetriesOnForeground() async throws {
        let origin = URL(string: "https://hestia.example")!
        let defaults = UserDefaults(suiteName: "AppStateTests.\(UUID())")!
        defaults.set(origin.absoluteString, forKey: BackendURLStore.userDefaultsKey)
        let keychain = TestSessionKeychain()
        let token = Data("legacy-token".utf8)
        keychain.seed(token, for: .legacy)
        keychain.setLocked(true)
        let store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        let active = StoredReceiptDeviceToken(server: origin, credential: fakeDeviceToken)
        let deviceStore = MemoryDeviceTokenStore(active)
        let pending = StoredReceiptDeviceToken(server: URL(string: "https://hestia.example:8443")!, credential: fakeDeviceToken)
        try deviceStore.savePendingRevocations([pending])
        let pairingAPI = RecordingPairingAPI()
        let pairing = ReceiptPairing(api: pairingAPI, store: deviceStore, serverURL: { origin })
        let mock = MockHestiaAPI()
        await mock.setCapabilities(Capabilities(user: "u"))
        let app = AppState(api: mock, receiptPairing: pairing, sessionStore: store, events: Self.noEvents)

        await app.bootstrap()

        XCTAssertNotNil(app.sessionStorageError)
        XCTAssertNil(store.currentSnapshot())
        XCTAssertTrue(keychain.mutations.isEmpty)
        XCTAssertEqual(keychain.storedData(for: .legacy), token)
        XCTAssertNil(keychain.storedData(for: .authoritative))
        XCTAssertNil(keychain.storedData(for: .legacyMigrated))
        XCTAssertEqual(defaults.string(forKey: BackendURLStore.userDefaultsKey), origin.absoluteString)
        XCTAssertEqual(deviceStore.load(), active)
        XCTAssertEqual(deviceStore.pending, [pending])
        let initialRevocations = await pairingAPI.revocations
        XCTAssertTrue(initialRevocations.isEmpty)
        let initialProbes = await mock.probeOrigins
        XCTAssertTrue(initialProbes.isEmpty)

        keychain.setLocked(false)
        app.enterForeground()
        try await waitUntil("the deferred session to finish migrating") { app.phase == .ready }
        XCTAssertNil(app.sessionStorageError)
        XCTAssertEqual(store.currentSnapshot()?.token, "legacy-token")
        XCTAssertEqual(deviceStore.load()?.credential, active.credential)
    }

    func testLaunchWithLinkedOverrideAndAbsentRecordProbesWithoutAuthenticating() async {
        let origin = URL(string: "https://hestia.example")!
        let defaults = UserDefaults(suiteName: "AppStateTests.\(UUID())")!
        let urls = BackendURLStore(userDefaults: defaults)
        urls.saveOverride(origin, sessionCommitID: UUID())
        let keychain = TestSessionKeychain()
        keychain.seed(Data("leftover-token".utf8), for: .legacy)
        let store = CredentialSessionStore(backendURLStore: urls, keychain: keychain)
        let mock = MockHestiaAPI()
        await mock.setFeatures([.capabilities])
        let app = AppState(api: mock, sessionStore: store, events: Self.noEvents)

        await app.bootstrap()

        XCTAssertEqual(app.phase, .needsAuth)
        XCTAssertTrue(app.serverFeatures?.supports(.capabilities) == true)
        XCTAssertNil(store.currentSnapshot())
        XCTAssertEqual(urls.currentEffectiveURL(), origin)
        XCTAssertNil(urls.loadOverrideRecord()?.sessionCommitID)
        XCTAssertNil(keychain.storedData(for: .legacy))
        let probes = await mock.probeOrigins
        let requests = await mock.calls
        let legacyVerifications = await mock.legacyVerificationRequests
        XCTAssertEqual(probes, [origin])
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(legacyVerifications.isEmpty)
    }

    @MainActor
    private struct QRFixture {
        static let target = URL(string: "https://hestia.example")!
        static let other = URL(string: "https://hestia.example:8443")!
        static let success = QRLoginResponse(ok: true, user: "qr-user", token: "qr-fixture")

        let keychain = TestSessionKeychain()
        let store: CredentialSessionStore
        let mock = MockHestiaAPI()
        let redeem: MockQRLogin
        let pairingAPI = RecordingPairingAPI(revokeError: nil)
        let devices: MemoryDeviceTokenStore
        let app: AppState
        let previous: BoundSession?

        init(oldOrigin: URL? = nil, oldActor: String = "qr-user", codePaired: Bool = false,
             result: Result<QRLoginResponse, QRLoginError> = .success(Self.success)) throws {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppStateTests.QR.\(UUID())"))
            store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
            if let oldOrigin {
                previous = try store.commitAuthoritative(origin: oldOrigin, actor: oldActor, token: "old-fixture")
            } else {
                previous = nil
            }
            let previousDevice: StoredReceiptDeviceToken? = codePaired ? previous.map {
                .init(server: $0.origin, provenance: .legacyCodeRedeem, sessionCommitID: $0.commitID,
                      credential: fakeDeviceToken)
            } : nil
            devices = MemoryDeviceTokenStore(previousDevice)
            let pairing = ReceiptPairing(api: pairingAPI, store: devices)
            redeem = MockQRLogin(result)
            app = AppState(api: mock, receiptPairing: pairing, sessionStore: store,
                           redeemQRLogin: redeem.redeem, events: { _ in AsyncStream { $0.finish() } })
        }

        static func payload() throws -> QRLoginPayload {
            let code = Data(repeating: 0, count: 14).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return try XCTUnwrap(QRLoginPayload(rawValue: "hestia-login:\(target.absoluteString)#\(code)"))
        }

        func permitQR() async {
            await mock.setFeatures(.init(authContract: 2, features: [.qrLogin, .capabilities],
                                         qrOrigin: Self.target, isLegacy: false))
        }
    }

    func testQRConfirmThenFailedRedeemLeavesPreviousOriginFeaturesAndCapabilitiesIntact() async throws {
        let fixture = try QRFixture(oldOrigin: QRFixture.other, result: .failure(.invalidCode))
        let oldFeatures = ServerFeatures(authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false)
        let oldCapabilities = Capabilities(user: "old-user")
        await fixture.mock.setFeatures(oldFeatures)
        await fixture.mock.setCapabilities(oldCapabilities)
        await fixture.app.bootstrap()
        let oldRecord = fixture.store.backendURLStore.loadOverrideRecord()
        let oldMutations = fixture.keychain.mutations
        await fixture.permitQR()

        do {
            try await fixture.app.signIn(with: QRFixture.payload())
            XCTFail("Expected redeem to fail")
        } catch let error as QRLoginError {
            XCTAssertEqual(error, .invalidCode)
        }

        XCTAssertEqual(fixture.store.currentSnapshot(), fixture.previous)
        XCTAssertEqual(fixture.store.backendURLStore.loadOverrideRecord(), oldRecord)
        XCTAssertEqual(fixture.keychain.mutations, oldMutations)
        XCTAssertEqual(fixture.app.phase, .ready)
        XCTAssertEqual(fixture.app.serverFeatures, oldFeatures)
        XCTAssertEqual(fixture.app.capabilities, oldCapabilities)
        let probes = await fixture.mock.probeOrigins
        let redeems = await fixture.redeem.origins
        XCTAssertEqual(probes, [QRFixture.other, QRFixture.target])
        XCTAssertEqual(redeems, [QRFixture.target])
    }

    func testQRSignOutDuringFeatureProbeDoesNotSpendCode() async throws {
        let payload = try QRFixture.payload()
        for resetSucceeds in [true, false] {
            let fixture = try QRFixture(oldOrigin: QRFixture.other)
            await fixture.permitQR()
            await fixture.mock.setHoldProbe()
            if !resetSucceeds { fixture.keychain.failNext(.delete(.authoritative)) }

            let signIn = Task { try await fixture.app.signIn(with: payload) }
            defer { Task { await fixture.mock.releaseProbe() } }
            try await waitUntil("the QR feature probe") { await fixture.mock.isProbeHeld }
            let didReset = await fixture.app.signOut()
            await fixture.mock.releaseProbe()
            do {
                try await signIn.value
                XCTFail("Expected sign-out to cancel the in-flight sign-in")
            } catch is CancellationError {}

            let redeems = await fixture.redeem.origins
            XCTAssertTrue(redeems.isEmpty)
            XCTAssertNil(fixture.app.serverFeatures)
            XCTAssertEqual(didReset, resetSucceeds)
            XCTAssertEqual(fixture.store.currentSnapshot(), resetSucceeds ? nil : fixture.previous)
            if resetSucceeds { XCTAssertEqual(fixture.app.phase, .needsAuth) }
        }
    }

    func testResetPausedBeforeRemoteLogoutPreservesNewQRToken() async throws {
        let fixture = try QRFixture(oldOrigin: QRFixture.other)
        let payload = try QRFixture.payload()
        await fixture.permitQR()
        await fixture.mock.setCapabilities(Capabilities(user: "qr-user"))
        await fixture.mock.setHoldLogout()

        let reset = Task { await fixture.app.signOut() }
        defer { Task { await fixture.mock.releaseLogout() } }
        try await waitUntil("the reset's remote logout") { await fixture.mock.isLogoutHeld }
        XCTAssertNil(fixture.store.currentSnapshot())
        XCTAssertNil(fixture.keychain.storedData(for: .authoritative))

        let signIn = Task { try await fixture.app.signIn(with: payload) }
        await Task.yield()
        let pendingProbes = await fixture.mock.probeOrigins
        XCTAssertTrue(pendingProbes.isEmpty)
        await fixture.mock.releaseLogout()
        try await signIn.value
        let signedOut = await reset.value

        XCTAssertTrue(signedOut)
        let logouts = await fixture.mock.logoutCredentials
        let logoutsBeforeProbe = await fixture.mock.logoutsFinishedAtProbe
        XCTAssertEqual(logouts, [.init(origin: QRFixture.other, actor: nil, token: "old-fixture")])
        XCTAssertEqual(logoutsBeforeProbe, [1])
        XCTAssertEqual(fixture.store.currentSnapshot()?.token, QRFixture.success.token)
        XCTAssertEqual(fixture.store.currentSnapshot()?.origin, QRFixture.target)
        XCTAssertEqual(fixture.app.phase, .ready)
    }

    func testQRSignOutDuringRedeemCannotCommitLateSuccess() async throws {
        let payload = try QRFixture.payload()
        for resetSucceeds in [true, false] {
            let fixture = try QRFixture(oldOrigin: QRFixture.other)
            let oldFeatures = ServerFeatures(authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false)
            let oldCapabilities = Capabilities(user: "qr-user")
            await fixture.mock.setFeatures(oldFeatures)
            await fixture.mock.setCapabilities(oldCapabilities)
            await fixture.app.bootstrap()
            let previousRecord = fixture.store.backendURLStore.loadOverrideRecord()
            let previousKeychain = fixture.keychain.storedData(for: .authoritative)
            let mutationsBeforeSignOut = fixture.keychain.mutations.count
            if !resetSucceeds { fixture.keychain.failNext(.delete(.authoritative)) }
            await fixture.permitQR()
            await fixture.redeem.holdNext()

            let signIn = Task { try await fixture.app.signIn(with: payload) }
            defer { Task { await fixture.redeem.release() } }
            try await waitUntil("the QR redeem request") { await fixture.redeem.isHeld }
            let didReset = await fixture.app.signOut()
            XCTAssertEqual(didReset, resetSucceeds)
            let signedOutRecord = fixture.store.backendURLStore.loadOverrideRecord()
            let mutationsAfterSignOut = fixture.keychain.mutations
            await fixture.redeem.release()
            do {
                try await signIn.value
                XCTFail("Expected sign-out to cancel the in-flight sign-in")
            } catch is CancellationError {}

            XCTAssertEqual(fixture.keychain.mutations, mutationsAfterSignOut)
            XCTAssertEqual(Array(mutationsAfterSignOut.dropFirst(mutationsBeforeSignOut)),
                           [.delete(.legacy), .delete(.authoritative)])
            XCTAssertEqual(fixture.store.currentSnapshot(), resetSucceeds ? nil : fixture.previous)
            XCTAssertEqual(fixture.keychain.storedData(for: .authoritative), resetSucceeds ? nil : previousKeychain)
            XCTAssertEqual(fixture.store.backendURLStore.loadOverrideRecord(), resetSucceeds ? signedOutRecord : previousRecord)
            XCTAssertEqual(fixture.app.savedBackendOverride, QRFixture.other)
            XCTAssertEqual(fixture.app.serverFeatures, oldFeatures)
            XCTAssertEqual(fixture.app.capabilities, resetSucceeds ? nil : oldCapabilities)
            XCTAssertEqual(fixture.app.phase, resetSucceeds ? .needsAuth : .ready)
        }
    }

    func testCompetingPasswordAndQRLoginCommitsLatestWinner() async throws {
        let payload = try QRFixture.payload()
        for qrWins in [true, false] {
            let fixture = try QRFixture()
            await fixture.permitQR()
            let winner = qrWins ? "qr-user" : "password-user"
            await fixture.mock.setCapabilities(Capabilities(user: winner))

            if qrWins {
                await fixture.mock.setHoldLogin()
                let password = Task { await fixture.app.login(user: "password-user", password: "fixture") }
                defer { Task { await fixture.mock.releaseLogin() } }
                try await waitUntil("the password request") {
                    await fixture.mock.count(.login("password-user", "fixture")) == 1
                }
                try await fixture.app.signIn(with: payload)
                await fixture.mock.releaseLogin()
                await password.value
            } else {
                await fixture.redeem.holdNext()
                let qr = Task { try await fixture.app.signIn(with: payload) }
                defer { Task { await fixture.redeem.release() } }
                try await waitUntil("the QR redeem request") { await fixture.redeem.isHeld }
                await fixture.app.login(user: "password-user", password: "fixture")
                await fixture.redeem.release()
                do {
                    try await qr.value
                    XCTFail("Expected the older QR attempt to be cancelled")
                } catch is CancellationError {}
            }

            XCTAssertEqual(fixture.store.currentSnapshot()?.actor, winner)
            XCTAssertEqual(fixture.keychain.mutations, [.write(.authoritative)])
            XCTAssertEqual(fixture.app.capabilities?.user, winner)
            XCTAssertEqual(fixture.app.phase, .ready)
        }
    }

    func testQRSameOriginSameUserRetainsDeviceTokenWithoutRevoke() async throws {
        let fixture = try QRFixture(oldOrigin: QRFixture.target, codePaired: true)
        await fixture.permitQR()
        await fixture.mock.setCapabilities(Capabilities(user: "qr-user"))

        try await fixture.app.signIn(with: QRFixture.payload())

        let session = try XCTUnwrap(fixture.store.currentSnapshot())
        let device = try XCTUnwrap(fixture.app.receiptPairing.credential(for: QRFixture.target))
        XCTAssertNotEqual(session.commitID, fixture.previous?.commitID)
        XCTAssertEqual(device.sessionCommitID, session.commitID)
        XCTAssertEqual(device.credential, fakeDeviceToken)
        XCTAssertNil(device.actor)
        XCTAssertTrue(fixture.devices.pending.isEmpty)
        let revocations = await fixture.pairingAPI.revocations
        let logouts = await fixture.mock.logoutCredentials
        let probes = await fixture.mock.probeOrigins
        let requests = await fixture.mock.capabilityRequests
        XCTAssertTrue(revocations.isEmpty)
        XCTAssertTrue(logouts.isEmpty)
        XCTAssertEqual(probes, [QRFixture.target])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.features, fixture.app.serverFeatures)
        XCTAssertEqual(fixture.app.phase, .ready)
    }

    func testCapabilities401KeepsCodePairedDeviceAfterSameActorQRSignIn() async throws {
        for handoffFails in [false, true] {
            let fixture = try QRFixture(oldOrigin: QRFixture.target, codePaired: true)
            let original = try XCTUnwrap(fixture.devices.load())
            await fixture.permitQR()
            let capabilities = Capabilities(user: QRFixture.success.user, ownBudget: .init(
                permissions: [.budgetReceiptsAdd], canView: false, canUseReceipts: true, canManageDevices: true
            ))
            await fixture.mock.setCapabilities(capabilities)
            await fixture.app.bootstrap()
            XCTAssertEqual(fixture.app.phase, .ready)
            if handoffFails { fixture.devices.failNextSave() }

            await fixture.mock.setCapabilitiesError(.unauthorized)
            await fixture.app.refresh()
            XCTAssertEqual(fixture.app.phase, .needsAuth)
            XCTAssertNil(fixture.store.currentSnapshot())
            XCTAssertEqual(fixture.keychain.storedData(for: .authoritative) != nil, handoffFails)
            XCTAssertEqual(fixture.devices.load()?.credential, original.credential)

            await fixture.mock.setCapabilities(capabilities)
            try await fixture.app.signIn(with: QRFixture.payload())

            let session = try XCTUnwrap(fixture.store.currentSnapshot())
            let retained = try XCTUnwrap(fixture.app.receiptPairing.credential(for: QRFixture.target))
            XCTAssertEqual(fixture.app.phase, .ready)
            XCTAssertEqual(session.actor, QRFixture.success.user)
            XCTAssertNotEqual(session.commitID, original.sessionCommitID)
            XCTAssertEqual(retained.sessionCommitID, session.commitID)
            XCTAssertEqual(retained.provenance, .legacyCodeRedeem)
            XCTAssertEqual(retained.credential, original.credential)
            XCTAssertTrue(fixture.devices.pending.isEmpty)
            let revocations = await fixture.pairingAPI.revocations
            XCTAssertTrue(revocations.isEmpty)
        }
    }

    func testQRInvalidOkOrEmptyTokenAbortsCommit() async throws {
        for invalid in [QRLoginResponse(ok: false, user: "u", token: "fixture"),
                        QRLoginResponse(ok: true, user: "u", token: ""),
                        QRLoginResponse(ok: true, user: "", token: "fixture")] {
            let fixture = try QRFixture(result: .success(invalid))
            await fixture.permitQR()
            await fixture.app.bootstrap()

            do {
                try await fixture.app.signIn(with: QRFixture.payload())
                XCTFail("Expected the invalid success response to fail")
            } catch let error as QRLoginError {
                XCTAssertEqual(error, .invalidCode)
            }

            XCTAssertNil(fixture.store.currentSnapshot())
            XCTAssertNil(fixture.app.savedBackendOverride)
            XCTAssertTrue(fixture.keychain.mutations.isEmpty)
            XCTAssertNil(fixture.app.serverFeatures)
            XCTAssertEqual(fixture.app.phase, .unconfigured)
        }
    }

    func testQRRejectsUnsupportedOrMismatchedFeatureProbeBeforeRedeem() async throws {
        let mismatched = ServerFeatures(authContract: 2, features: [.qrLogin], qrOrigin: QRFixture.other, isLegacy: false)
        for (features, expected) in [(ServerFeatures.legacy, QRLoginError.unsupported), (mismatched, .originMismatch)] {
            let fixture = try QRFixture()
            await fixture.mock.setFeatures(features)

            do {
                try await fixture.app.signIn(with: QRFixture.payload())
                XCTFail("Expected preflight to fail")
            } catch let error as QRLoginError {
                XCTAssertEqual(error, expected)
            }
            let redeems = await fixture.redeem.origins
            XCTAssertTrue(redeems.isEmpty)
            XCTAssertNil(fixture.app.serverFeatures)
            XCTAssertNil(fixture.store.currentSnapshot())
        }
    }

    func testQRKeychainFailurePreservesOldSessionAndDevice() async throws {
        let fixture = try QRFixture(oldOrigin: QRFixture.other, codePaired: true)
        await fixture.mock.setCapabilities(Capabilities(user: "qr-user"))
        await fixture.app.bootstrap()
        let record = fixture.store.backendURLStore.loadOverrideRecord()
        let device = fixture.devices.load()
        let stored = fixture.keychain.storedData(for: .authoritative)
        fixture.keychain.failNext(.write(.authoritative))
        await fixture.permitQR()

        do {
            try await fixture.app.signIn(with: QRFixture.payload())
            XCTFail("Expected credential storage to fail")
        } catch let error as APIError {
            XCTAssertEqual(error, .credentialStorage)
        }

        XCTAssertEqual(fixture.app.phase, .ready)
        XCTAssertEqual(fixture.app.serverFeatures, .legacy)
        XCTAssertEqual(fixture.app.capabilities?.user, "qr-user")
        XCTAssertEqual(fixture.store.currentSnapshot(), fixture.previous)
        XCTAssertEqual(fixture.store.backendURLStore.loadOverrideRecord(), record)
        XCTAssertEqual(fixture.keychain.storedData(for: .authoritative), stored)
        XCTAssertEqual(fixture.app.receiptPairing.credential(for: QRFixture.other), device)
        let revocations = await fixture.pairingAPI.revocations
        let logouts = await fixture.mock.logoutCredentials
        XCTAssertTrue(revocations.isEmpty)
        XCTAssertTrue(logouts.isEmpty)
    }

    func testQROriginOrUserChangeCleansUpUsingOldIssuingOrigins() async throws {
        for (origin, actor) in [(QRFixture.other, "qr-user"), (QRFixture.target, "old-user")] {
            let fixture = try QRFixture(oldOrigin: origin, oldActor: actor, codePaired: true)
            await fixture.mock.setCapabilities(Capabilities(user: "qr-user"))
            await fixture.permitQR()

            try await fixture.app.signIn(with: QRFixture.payload())

            XCTAssertNil(fixture.devices.load())
            let revocations = await fixture.pairingAPI.revocations
            let logouts = await fixture.mock.logoutCredentials
            XCTAssertEqual(revocations, [.init(token: fakeDeviceToken, origin: origin)])
            XCTAssertEqual(logouts, [.init(origin: origin, actor: nil, token: "old-fixture")])
            XCTAssertEqual(fixture.store.currentSnapshot()?.origin, QRFixture.target)
            XCTAssertEqual(fixture.store.currentSnapshot()?.token, QRFixture.success.token)
        }
    }

    func testQRFailedAuthoritativeWriteDoesNotWarnAboutStillBoundReceiptDevice() async throws {
        let fixture = try QRFixture(oldOrigin: QRFixture.other, codePaired: true)
        await fixture.mock.setCapabilities(Capabilities(user: "qr-user"))
        await fixture.app.bootstrap()
        let active = try XCTUnwrap(fixture.devices.load())
        let pairing = fixture.app.receiptPairing
        fixture.keychain.failNext(.write(.authoritative))
        await fixture.permitQR()

        do {
            try await fixture.app.signIn(with: QRFixture.payload())
            XCTFail("Expected credential storage to fail")
        } catch let error as APIError {
            XCTAssertEqual(error, .credentialStorage)
        }

        pairing.refreshStatus()
        XCTAssertNil(pairing.revocationNotice)
        XCTAssertEqual(pairing.credential(for: QRFixture.other), active)
        XCTAssertEqual(fixture.devices.pending, [active])

        let detached = StoredReceiptDeviceToken(server: QRFixture.target, credential: fakeDeviceToken)
        try fixture.devices.savePendingRevocations([active, detached])
        pairing.refreshStatus()
        XCTAssertNotNil(pairing.revocationNotice)
        try await waitUntil("the detached token to be revoked without warning about the active token") {
            fixture.devices.pending == [active] && pairing.revocationNotice == nil
        }
        let revocations = await fixture.pairingAPI.revocations
        XCTAssertEqual(revocations, [.init(token: fakeDeviceToken, origin: QRFixture.target)])
    }
}
