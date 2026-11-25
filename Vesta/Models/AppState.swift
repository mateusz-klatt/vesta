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
    private var authorization: (features: ServerFeatures?, capabilities: Capabilities?) = (nil, nil)
    var serverFeatures: ServerFeatures? { authorization.features }
    var capabilities: Capabilities? { authorization.capabilities }
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
    private(set) var backendURLString: String
    private(set) var sessionStorageError: APIError?

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
    private let sessionStore: CredentialSessionStore
    private var backendURLStore: BackendURLStore { sessionStore.backendURLStore }
    private var activeOrigin: URL {
        sessionStore.currentSnapshot()?.origin ?? backendURLStore.currentEffectiveURL()
    }
    let receiptPairing: ReceiptPairing
    private let makeEvents: @Sendable (SSESessionSnapshot) -> AsyncStream<EventStream.Event>
    private let eventRetryDelay: @Sendable (Duration) async throws -> Void
    private(set) var eventTask: Task<Void, Never>?
    private var eventRunID: UUID?
    private var eventStage: EventStage?
    private var isInForeground = true
    private var lifecycleGeneration = 0
    private var didBootstrap = false
    private var needsSessionRestore = true
    private var isRestoringSession = false
    private var retryMigrationCleanup = false
    private var rejectedLegacyBearer = false
    private var retryInvalidation = false
    private var authAttempt = 0
    /// Bumped on sign-out and backend change so a login still in flight
    /// can't pair against the new session.
    private var sessionGeneration = 0
    private var capabilitiesGeneration = 0
    private var discoveryGeneration = 0
    private var refreshRevision = 0
    private var activeCapabilitiesRefresh: CapabilityRefresh?
    @ObservationIgnored private weak var openReceiptFlow: ReceiptFlow?
    /// A new login waits for cleanup and the current backend switch's connection.
    private var resetTask: Task<Void, Never>?
    private weak var activeBudgetStore: BudgetStore?
    private weak var activeAgendaStore: AgendaStore?

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

    private struct RefreshSnapshot: Equatable {
        let origin: URL
        let session: Int
        let revision: Int
    }

    private enum SessionRestore {
        case ready
        case verifiedLegacy(ServerFeatures, Capabilities)
        case deferred
    }

    private struct CleanupSnapshot: Sendable {
        let oldSession: BoundSession?
        let detachedDevice: StoredReceiptDeviceToken?
    }

    private struct CapabilityRefresh {
        let source: RefreshSource
        let snapshot: RefreshSnapshot
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

    private var currentRefreshSnapshot: RefreshSnapshot {
        RefreshSnapshot(origin: activeOrigin, session: sessionGeneration, revision: refreshRevision)
    }

    private func isCurrent(_ snapshot: RefreshSnapshot, phase expectedPhase: Phase) -> Bool {
        !Task.isCancelled && snapshot == currentRefreshSnapshot && phase == expectedPhase
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
        guard nativeBudgetEnabled, serverFeatures?.supports(.budgetNativeRead) == true,
              capabilities?.effectiveDeviceEligiblePermissions.contains(.budgetView) == true else { return nil }
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

    var calendarAPI: (any CalendarAPI)? {
        guard serverFeatures?.supports(.calendarInstances) == true, capabilities?.canViewCalendar == true else { return nil }
        return api as? any CalendarAPI
    }

    func makeAgendaStore(calendar: Calendar = .current) -> AgendaStore? {
        guard phase == .ready, let api = calendarAPI else { return nil }
        closeAgenda()
        let session = sessionGeneration
        let store = AgendaStore(
            api: api, calendar: calendar,
            onForbidden: { [weak self] in
                guard let self, sessionGeneration == session else { return }
                closeAgenda()
                // The discarded sheet handles the denial locally. Refresh the shared grants.
                _ = beginCapabilityRefresh(source: .denial)
            },
            onUnauthorized: { [weak self] in
                guard let self, sessionGeneration == session else { return }
                invalidateSession()
            }
        )
        activeAgendaStore = store
        return store
    }

    func closeAgenda() {
        activeAgendaStore?.discard()
        activeAgendaStore = nil
    }

    var hasLights: Bool { allDevices.contains { $0.device._type == "light" } }
    var hasBlinds: Bool { allDevices.contains { $0.device._type == "blind" } }

    func makeReceiptFlow(janitor: ReceiptDraftJanitor = .shared) -> ReceiptFlow? {
        guard let api = receiptsAPI else { return nil }
        let session = sessionGeneration
        let access = receiptAccessGeneration
        let origin = activeOrigin.absoluteString
        let flow = ReceiptFlow(api: api, allowsMatching: { [weak self] in
            guard let self, hasReceiptAccess(session: session, generation: access) else { return false }
            return capabilities?.canMatchReceipts == true
        }, janitor: janitor, server: { origin })
        openReceiptFlow = flow
        return flow
    }

    init(api: (any HestiaAPI)? = nil,
         receiptPairing: ReceiptPairing? = nil,
         sessionStore: CredentialSessionStore = CredentialSessionStore(),
         events: @escaping @Sendable (SSESessionSnapshot) -> AsyncStream<EventStream.Event> = { EventStream.changes(snapshot: $0) },
         eventRetryDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let backendURLStore = sessionStore.backendURLStore
        let receiptPairing = receiptPairing ?? ReceiptPairing(serverURL: { backendURLStore.currentEffectiveURL() })
        self.sessionStore = sessionStore
        self.receiptPairing = receiptPairing
        self.api = api ?? APIClient(receiptPairing: receiptPairing, sessionStore: sessionStore)
        self.makeEvents = events
        self.eventRetryDelay = eventRetryDelay
        backendURLString = backendURLStore.currentEffectiveURL().absoluteString
        tempScale = TempScale(rawValue: UserDefaults.standard.string(forKey: Self.tempScaleKey) ?? "C") ?? .celsius
        appLanguage = UserDefaults.standard.string(forKey: Self.languageKey)
        receiptPairing.bindSessionStore(sessionStore)
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
        if let raw = Self.launchValue("-vesta.url"), BackendURLStore.canonicalize(raw) != nil {
            if saveAndConnect(raw), let user = Self.launchValue("-vesta.user"), let pass = Self.launchValue("-vesta.pass") {
                await login(user: user, password: pass)
            }
            return
        }
        #endif
        await connect(configuredOnly: true)
    }

    #if DEBUG
    private static func launchValue(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    #endif

    func connect() async { await connect(configuredOnly: false) }

    private func connect(configuredOnly: Bool) async {
        guard !Task.isCancelled else { return }
        let generation = sessionGeneration
        let restored: SessionRestore = needsSessionRestore ? await restoreSession() : .ready
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        guard !configuredOnly || backendURLStore.hasOverride() else {
            if case .ready = restored { phase = .unconfigured }
            return
        }
        switch restored {
        case .deferred:
            return
        case .ready:
            prepareInitialAuth()
            await finishInitialAuth()
        case .verifiedLegacy(let features, let capabilities):
            prepareInitialAuth(keepingFeatures: false)
            publishAuthorization(features: features, capabilities: capabilities)
            await finishInitialAuth(using: currentFence)
        }
    }

    private func restoreSession() async -> SessionRestore {
        guard !isRestoringSession else { return .deferred }
        isRestoringSession = true
        defer { isRestoringSession = false }
        do {
            switch try sessionStore.bootstrap() {
            case .ready(let retryCleanup):
                finishSessionRestore(retryCleanup: retryCleanup)
                return .ready
            case .signedOut(let retryCleanup):
                finishSessionRestore(retryCleanup: retryCleanup)
                phase = .needsAuth
                _ = await refreshCapabilities(source: .foreground)
                return .deferred
            case .verifyLegacy(let candidate):
                return await verifyAndMigrate(candidate)
            }
        } catch {
            reportSessionStorageFailure(error)
            return .deferred
        }
    }

    private func verifyAndMigrate(_ candidate: BoundSession) async -> SessionRestore {
        let snapshot = currentRefreshSnapshot
        let attempt = authAttempt
        var features: ServerFeatures?
        let resolved: Capabilities
        do {
            let probe = try await api.probeFeatures(on: candidate.origin)
            guard isCurrentRestore(snapshot, attempt: attempt) else { return .deferred }
            features = probe
            resolved = try await api.verifyLegacySession(candidate, features: probe)
        } catch {
            guard isCurrentRestore(snapshot, attempt: attempt), !APIError.isCancellation(error) else { return .deferred }
            let failure = APIError.wrap(error)
            if failure == .unauthorized {
                // A rejected bearer stays on disk until an explicit reset or successful login.
                needsSessionRestore = false
                rejectedLegacyBearer = true
                publishAuthorization(features: features, capabilities: nil)
                phase = .needsAuth
            } else {
                phase = .failed(failure)
            }
            return .deferred
        }
        guard isCurrentRestore(snapshot, attempt: attempt), let features else { return .deferred }
        do {
            try receiptPairing.bindLegacyCredential(origin: candidate.origin, actor: resolved.user)
            let retryCleanup = try sessionStore.completeLegacyMigration(candidate, actor: resolved.user)
            finishSessionRestore(retryCleanup: retryCleanup)
            return .verifiedLegacy(features, resolved)
        } catch {
            reportSessionStorageFailure(error)
            return .deferred
        }
    }

    private func finishSessionRestore(retryCleanup: Bool) {
        retryMigrationCleanup = retryCleanup
        needsSessionRestore = false
        sessionStorageError = nil
        backendURLString = activeOrigin.absoluteString
        receiptPairing.retryInterruptedDetach()
    }

    private func isCurrentRestore(_ snapshot: RefreshSnapshot, attempt: Int) -> Bool {
        !Task.isCancelled && snapshot == currentRefreshSnapshot && attempt == authAttempt
    }

    /// Onboarding / "change backend": validate, then clear local credentials before changing origin.
    @discardableResult
    func saveAndConnect(_ raw: String) -> Bool {
        sessionStorageError = nil
        guard let url = BackendURLStore.canonicalize(raw) else { return false }
        let changed = !OriginMatcher.matches(url, activeOrigin)
        do {
            let cleanup = try resetLocalSession(savingOverride: url)
            let previousOrigin = cleanup.oldSession?.origin
            prepareInitialAuth(keepingFeatures: !changed && (previousOrigin.map { OriginMatcher.matches($0, url) } ?? true))
            scheduleCleanup(cleanup, reconnect: true)
            return true
        } catch {
            reportSessionStorageFailure(error)
            return false
        }
    }

    func login(user: String, password: String) async {
        sessionStorageError = nil
        authAttempt += 1
        let attempt = authAttempt
        let generation = sessionGeneration
        let origin = activeOrigin
        await resetTask?.value
        guard isCurrentLogin(attempt, generation: generation, origin: origin) else { return }
        let actor: String
        let token: String
        do {
            let result = try await api.login(user: user, password: password, on: origin)
            guard result.ok, !result.user.isEmpty,
                  let receivedToken = result.token, !receivedToken.isEmpty else { throw APIError.unauthorized }
            actor = result.user
            token = receivedToken
        } catch {
            guard isCurrentLogin(attempt, generation: generation, origin: origin), !APIError.isCancellation(error) else { return }
            if phase == .ready { notice = APIError.wrap(error) } else { phase = .failed(APIError.wrap(error)) }
            return
        }
        guard isCurrentLogin(attempt, generation: generation, origin: origin) else { return }

        let oldSession: BoundSession?
        var stagedDevice: StoredReceiptDeviceToken?
        let committed: BoundSession
        do {
            if retryInvalidation { try clearInvalidatedSession() }
            oldSession = sessionStore.currentSnapshot()
            committed = try sessionStore.commitAuthoritative(origin: origin, actor: actor, token: token) { replacement in
                stagedDevice = try receiptPairing.prepareForLogin(from: oldSession, to: replacement)
            }
        } catch {
            reportSessionStorageFailure(error)
            return
        }
        sessionGeneration += 1
        let committedGeneration = sessionGeneration
        needsSessionRestore = false
        if rejectedLegacyBearer {
            retryMigrationCleanup = sessionStore.retryLegacyMigrationCleanup()
            rejectedLegacyBearer = false
        }
        backendURLString = committed.origin.absoluteString
        prepareInitialAuth()
        let detached = stagedDevice.flatMap { receiptPairing.finishStagedDetachment($0) }
        let logout = oldSession.flatMap { old -> BoundSession? in
            let sameOrigin = OriginMatcher.matches(old.origin, committed.origin)
            guard !sameOrigin || (old.actor != committed.actor && old.token != committed.token) else { return nil }
            return old
        }
        let cleanupTask = logout != nil || detached != nil
            ? scheduleCleanup(.init(oldSession: logout, detachedDevice: detached)) : nil
        await finishInitialAuth()
        await cleanupTask?.value
        guard committedGeneration == sessionGeneration, !Task.isCancelled else { return }
        await pairReceiptsAfterLogin(user: user, password: password, server: committed.origin)
    }

    private func isCurrentLogin(_ attempt: Int, generation: Int, origin: URL) -> Bool {
        !Task.isCancelled && attempt == authAttempt && generation == sessionGeneration
            && OriginMatcher.matches(origin, activeOrigin)
    }

    private func prepareInitialAuth(keepingFeatures: Bool = true) {
        clearAuthorization(keeping: keepingFeatures ? serverFeatures : nil)
        phase = .connecting
    }

    private func finishInitialAuth() async {
        guard let fence = await refreshCapabilities(source: .initialAuth) else { return }
        await finishInitialAuth(using: fence)
    }

    private func finishInitialAuth(using fence: Fence) async {
        guard isCurrent(fence) else { return }
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

    @discardableResult
    func signOut() async -> Bool {
        sessionStorageError = nil
        do {
            let cleanup = try resetLocalSession()
            clearAuthorization(keeping: serverFeatures)
            phase = .needsAuth
            let task = scheduleCleanup(cleanup)
            await task.value
            return true
        } catch {
            reportSessionStorageFailure(error)
            return false
        }
    }

    private func resetLocalSession(savingOverride: URL? = nil) throws -> CleanupSnapshot {
        let originalOrigin = activeOrigin
        var stagedDevice: StoredReceiptDeviceToken?
        var preservesOrigin = false
        let oldSession = try sessionStore.clearAuthoritative(savingOverride: savingOverride) { old in
            preservesOrigin = savingOverride.map { OriginMatcher.matches($0, old?.origin ?? originalOrigin) } ?? false
            if preservesOrigin {
                try receiptPairing.prepareCodeReauthentication(from: old)
            } else {
                stagedDevice = try receiptPairing.stageActiveDetachment(receiptPairing.currentActiveToken())
            }
        }
        sessionGeneration += 1
        needsSessionRestore = false
        retryMigrationCleanup = false
        rejectedLegacyBearer = false
        retryInvalidation = false
        backendURLString = activeOrigin.absoluteString
        let detachedDevice = preservesOrigin ? nil : receiptPairing.finishStagedDetachment(stagedDevice)
        return CleanupSnapshot(oldSession: oldSession, detachedDevice: detachedDevice)
    }

    @discardableResult
    private func scheduleCleanup(_ snapshot: CleanupSnapshot, reconnect: Bool = false) -> Task<Void, Never> {
        let previous = resetTask
        let generation = sessionGeneration
        let cleanup = Task { [api, receiptPairing] in
            if let token = snapshot.detachedDevice { try? await receiptPairing.revokeDetached(token) }
            if let session = snapshot.oldSession { await api.remoteLogout(token: session.token, origin: session.origin) }
        }
        resetTask = Task { [weak self] in
            await previous?.value
            await cleanup.value
            guard reconnect, let self, generation == sessionGeneration else { return }
            await connect()
        }
        return cleanup
    }

    private func invalidateSession(features: ServerFeatures? = nil) {
        do {
            try clearInvalidatedSession()
        } catch {
            sessionStore.discardSnapshot()
            retryInvalidation = true
        }
        needsSessionRestore = false
        retryMigrationCleanup = false
        sessionGeneration += 1
        clearAuthorization(keeping: features ?? serverFeatures)
        phase = .needsAuth
        if !retryInvalidation { receiptPairing.retryInterruptedDetach() }
    }

    private func clearInvalidatedSession() throws {
        try sessionStore.clearAuthoritative { old in
            try receiptPairing.prepareCodeReauthentication(from: old)
        }
        retryInvalidation = false
    }

    private func reportSessionStorageFailure(_ error: any Error) {
        let failure = APIError.wrap(error)
        sessionStorageError = failure
        if phase == .ready { notice = failure } else { phase = .failed(failure) }
    }

    private func retrySessionPersistence() {
        if retryInvalidation {
            try? clearInvalidatedSession()
        } else if retryMigrationCleanup {
            retryMigrationCleanup = sessionStore.retryLegacyMigrationCleanup()
        }
    }

    private func cancelCapabilityRefresh() {
        refreshRevision += 1
        activeCapabilitiesRefresh?.task.cancel()
        activeCapabilitiesRefresh = nil
    }

    private func clearAuthorization(keeping features: ServerFeatures?) {
        cancelCapabilityRefresh()
        publishAuthorization(features: features, capabilities: nil)
        notice = nil
    }

    // MARK: - Capabilities

    private func refreshCapabilities(source: RefreshSource) async -> Fence? {
        guard !Task.isCancelled, let task = beginCapabilityRefresh(source: source) else { return nil }
        return await task.value
    }

    private func beginCapabilityRefresh(source: RefreshSource) -> Task<Fence?, Never>? {
        let expectedPhase = phase
        guard expectedPhase == (source == .initialAuth ? .connecting : .ready)
                || (source == .foreground && expectedPhase == .needsAuth) else { return nil }
        // A denial needs an answer requested after the rejection. Explicit
        // refreshes own their follow-up work, so only like denials can share it.
        if let active = activeCapabilitiesRefresh, active.snapshot == currentRefreshSnapshot,
           source == .denial, active.source == .denial {
            return active.task
        }
        cancelCapabilityRefresh()
        let snapshot = currentRefreshSnapshot
        let task = Task { [weak self] in
            await self?.performCapabilityRefresh(source: source, snapshot: snapshot, phase: expectedPhase)
        }
        activeCapabilitiesRefresh = CapabilityRefresh(source: source, snapshot: snapshot, task: task)
        return task
    }

    private func performCapabilityRefresh(source: RefreshSource, snapshot: RefreshSnapshot, phase expectedPhase: Phase) async -> Fence? {
        defer {
            if activeCapabilitiesRefresh?.snapshot == snapshot { activeCapabilitiesRefresh = nil }
        }
        guard isCurrent(snapshot, phase: expectedPhase) else { return nil }
        let features: ServerFeatures
        do {
            features = try await api.probeFeatures(on: snapshot.origin)
        } catch {
            if isCurrent(snapshot, phase: expectedPhase), source == .initialAuth, !APIError.isCancellation(error) {
                phase = .failed(APIError.wrap(error))
            }
            return nil
        }
        guard isCurrent(snapshot, phase: expectedPhase) else { return nil }
        if expectedPhase == .needsAuth {
            publishAuthorization(features: features, capabilities: nil)
            return nil
        }
        do {
            let resolved = try await api.capabilities(on: snapshot.origin, features: features)
            guard isCurrent(snapshot, phase: expectedPhase) else { return nil }
            publishAuthorization(features: features, capabilities: resolved)
            if source == .foreground || source == .userPull { notice = nil }
            return currentFence
        } catch {
            guard isCurrent(snapshot, phase: expectedPhase), !APIError.isCancellation(error) else { return nil }
            switch APIError.wrap(error) {
            case .unauthorized:
                invalidateSession(features: features)
            case .forbidden:
                publishAuthorization(features: features, capabilities: nil)
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

    private func publishAuthorization(features: ServerFeatures?, capabilities published: Capabilities?) {
        if capabilities != published { capabilitiesGeneration += 1 }
        if capabilities?.canUseReceipts == true, published?.canUseReceipts != true {
            receiptAccessGeneration += 1
        }
        authorization = (features, published)
        receiptPairing.setUnauthenticatedOrigin(published?.isAuthOff == true ? activeOrigin : nil)
        if published != nil { receiptPairing.refreshStatus() }
        if calendarAPI == nil { closeAgenda() }
        if budgetAPI == nil { closeBudget() }
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
        if didBootstrap, needsSessionRestore {
            Task { [weak self] in await self?.connect(configuredOnly: true) }
            return
        }
        retrySessionPersistence()
        if !needsSessionRestore, !retryInvalidation { receiptPairing.retryInterruptedDetach() }
        guard let task = beginCapabilityRefresh(source: .foreground) else { return }
        let lifecycle = lifecycleGeneration
        Task { [weak self] in
            guard let fence = await task.value, let self, isCurrent(fence), lifecycle == lifecycleGeneration,
                  canViewIOC else { return }
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
        closeAgenda()
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
        let session = sessionStore.currentSnapshot()
        let snapshot = SSESessionSnapshot(origin: session?.origin ?? activeOrigin, session: session)
        for await event in makeEvents(snapshot) {
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
