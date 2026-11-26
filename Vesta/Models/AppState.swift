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
    private let redeemQRLogin: @Sendable (URL, String) async throws -> QRLoginResponse
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
    private var budgetGeneration = 0
    private var handledBudgetDenialGeneration: Int?
    private(set) var budgetDenialHandlingCount = 0
    private weak var activeReceiptReviewStore: ReceiptReviewStore?
    private var receiptReviewGeneration = 0
    private var handledReceiptReviewDenialGeneration: Int?
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

    private struct AuthAttempt {
        let id: Int
        let session: Int
    }

    private struct LoginCommit {
        let session: BoundSession
        let hydration: CapabilityRefresh?
        let cleanup: Task<Void, Never>?
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
    var canScanQRLogin: Bool {
        phase == .unconfigured || (phase == .needsAuth && serverFeatures?.supports(.qrLogin) == true)
    }
    var savedBackendOverride: URL? {
        backendURLStore.loadOverrideRecord().flatMap { URL(string: $0.urlString) }
    }
    var canViewIOC: Bool { capabilities?.canViewIOC == true }
    var isReadOnly: Bool { capabilities?.canControlIOC != true }
    var receiptsAPI: (any ReceiptsAPI)? {
        guard capabilities?.canUseReceipts == true, let api = api as? any ReceiptsAPI else { return nil }
        return scopedReceiptsAPI(api, scope: currentReceiptScope)
    }

    var receiptsUseExchange: Bool { serverFeatures?.supports(.deviceExchange) == true }

    private var currentReceiptScope: ReceiptSessionScope {
        let session = sessionStore.currentSnapshot()
        let origin = session?.origin ?? activeOrigin
        let token = receiptPairing.credential(for: origin, session: session)
        return .init(origin: origin, actor: session?.actor, ownerKey: token?.ownerKey, credential: token?.credential)
    }

    private func receiptScopeValidator(requiresAccess: Bool) -> @MainActor @Sendable (ReceiptSessionScope) -> Bool {
        let session = sessionGeneration
        let access = receiptAccessGeneration
        return { [weak self] scope in
            guard let self, session == sessionGeneration, scope == currentReceiptScope,
                  capabilities?.canUseReceipts == true else { return false }
            return !requiresAccess || hasReceiptAccess(session: session, generation: access)
        }
    }

    private func scopedReceiptsAPI(_ api: any ReceiptsAPI, scope: ReceiptSessionScope) -> any ReceiptsAPI {
        DenialReportingReceiptsAPI(api: api, scope: scope,
                                   isScopeCurrent: receiptScopeValidator(requiresAccess: true),
                                   isCleanupScopeCurrent: receiptScopeValidator(requiresAccess: false)) { [weak self] error, scope in
            self?.handleReceiptFailure(error, scope: scope)
        }
    }

    private func hasReceiptAccess(session: Int, generation: Int) -> Bool {
        sessionGeneration == session && receiptAccessGeneration == generation && capabilities?.canUseReceipts == true
    }


    /// Native budget reads stay hidden until hestia advertises
    /// `budget_native_read` and capabilities grant `budget.view` (V2 plan §10).
    /// Only tests and the DEBUG launch override turn this on.
    var nativeBudgetEnabled = AppConfig.nativeBudgetEnabledForBuild {
        didSet {
            if nativeBudgetEnabled != oldValue { closeBudget() }
        }
    }
    var budgetAPI: (any BudgetAPI)? {
        guard let api = api as? any BudgetAPI, let session = sessionStore.currentSnapshot(),
              NativeBudgetGate.isEligible(enabled: nativeBudgetEnabled, features: serverFeatures, capabilities: capabilities),
              let token = receiptPairing.nativeBudgetCredential(for: session.origin, session: session) else { return nil }
        let generation = budgetGeneration
        let scope = ReceiptSessionScope(
            origin: session.origin, actor: session.actor, ownerKey: token.ownerKey, credential: token.credential
        )
        return SessionBoundBudgetAPI(api: api, scope: scope, isCurrent: { [weak self] in
            self?.isCurrentBudgetAPI(session: session, token: token, generation: generation) == true
        }, onDenial: { [weak self] error in
            guard let self, handledBudgetDenialGeneration != generation,
                  isCurrentBudgetAPI(session: session, token: token, generation: generation) else { return false }
            handledBudgetDenialGeneration = generation
            budgetDenialHandlingCount += 1
            closeBudget()
            switch error {
            case .forbidden: handleDeviceFailure(.forbidden, used: token)
            case .expiredDeviceToken: handleDeviceFailure(.expiredDeviceToken, used: token)
            case .revokedDeviceToken: handleDeviceFailure(.revokedDeviceToken, used: token)
            case .invalidDeviceToken: handleDeviceFailure(.invalidDeviceToken, used: token)
            case .unauthorized: _ = beginCapabilityRefresh(source: .denial)
            default: break
            }
            return true
        })
    }

    private func isCurrentBudgetAPI(
        session: BoundSession,
        token: StoredReceiptDeviceToken,
        generation: Int
    ) -> Bool {
        guard generation == budgetGeneration, session == sessionStore.currentSnapshot(),
              NativeBudgetGate.isEligible(enabled: nativeBudgetEnabled, features: serverFeatures,
                                          capabilities: capabilities) else { return false }
        return token == receiptPairing.nativeBudgetCredential(for: session.origin, session: session)
    }

    func makeBudgetStore(now: Date = Date()) -> BudgetStore? {
        guard phase == .ready else { return nil }
        closeBudget()
        guard let api = budgetAPI else { return nil }
        let store = BudgetStore(api: api, now: now)
        activeBudgetStore = store
        return store
    }

    func closeBudget() {
        budgetGeneration += 1
        activeBudgetStore?.clear()
        activeBudgetStore = nil
    }

    var receiptReviewEnabled = AppConfig.receiptReviewEnabledForBuild {
        didSet {
            if receiptReviewEnabled != oldValue { closeReceiptReview() }
        }
    }

    var receiptReviewAPI: (any ReceiptReviewAPI)? {
        guard phase == .ready, let api = api as? any ReceiptReviewAPI,
              let session = sessionStore.currentSnapshot(),
              ReceiptReviewGate.isEligible(enabled: receiptReviewEnabled, capabilities: capabilities),
              let token = receiptPairing.receiptReviewCredential(
                for: session.origin, session: session, enabled: receiptReviewEnabled
              ) else { return nil }
        let generation = receiptReviewGeneration
        let scope = ReceiptSessionScope(
            origin: session.origin, actor: session.actor, ownerKey: token.ownerKey, credential: token.credential
        )
        return SessionBoundReceiptReviewAPI(api: api, scope: scope, isCurrent: { [weak self] in
            self?.isCurrentReceiptReviewAPI(session: session, token: token, generation: generation) == true
        }, onDenial: { [weak self] error in
            guard let self, handledReceiptReviewDenialGeneration != generation,
                  isCurrentReceiptReviewAPI(session: session, token: token, generation: generation) else { return false }
            handledReceiptReviewDenialGeneration = generation
            closeReceiptReview()
            switch error {
            case .forbidden, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken:
                handleDeviceFailure(error, used: token)
            case .api(.unauthorized):
                _ = beginCapabilityRefresh(source: .denial)
            default:
                break
            }
            return true
        })
    }

    private func isCurrentReceiptReviewAPI(
        session: BoundSession,
        token: StoredReceiptDeviceToken,
        generation: Int
    ) -> Bool {
        guard phase == .ready, generation == receiptReviewGeneration, session == sessionStore.currentSnapshot(),
              ReceiptReviewGate.isEligible(enabled: receiptReviewEnabled, capabilities: capabilities) else { return false }
        return token == receiptPairing.receiptReviewCredential(
            for: session.origin, session: session, enabled: receiptReviewEnabled
        )
    }

    func makeReceiptReviewStore() -> ReceiptReviewStore? {
        closeReceiptReview()
        guard let api = receiptReviewAPI, let session = sessionStore.currentSnapshot(),
              let token = receiptPairing.receiptReviewCredential(
                for: session.origin, session: session, enabled: receiptReviewEnabled
              ) else { return nil }
        let generation = receiptReviewGeneration
        let scope = ReceiptSessionScope(
            origin: session.origin, actor: session.actor, ownerKey: token.ownerKey, credential: token.credential
        )
        let store = ReceiptReviewStore(api: api, scope: scope, allowsMatching: { [weak self] in
            guard let self, isCurrentReceiptReviewAPI(session: session, token: token, generation: generation),
                  let capabilities else { return false }
            return ReceiptReviewGate.allowsMatching(token, capabilities: capabilities)
        }, isCurrent: { [weak self] in
            self?.isCurrentReceiptReviewAPI(session: session, token: token, generation: generation) == true
        })
        activeReceiptReviewStore = store
        return store
    }

    func closeReceiptReview() {
        receiptReviewGeneration += 1
        activeReceiptReviewStore?.clear()
        activeReceiptReviewStore = nil
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
        guard capabilities?.canUseReceipts == true, let api = api as? any ReceiptsAPI else { return nil }
        let session = sessionGeneration
        let access = receiptAccessGeneration
        let scope = currentReceiptScope
        let flow = ReceiptFlow(api: scopedReceiptsAPI(api, scope: scope), allowsMatching: { [weak self] in
            guard let self, hasReceiptAccess(session: session, generation: access) else { return false }
            return capabilities?.canMatchReceipts == true
        }, janitor: janitor, scope: scope,
                               isScopeCurrent: receiptScopeValidator(requiresAccess: true),
                               isCleanupScopeCurrent: receiptScopeValidator(requiresAccess: false))
        openReceiptFlow = flow
        return flow
    }

    init(api: (any HestiaAPI)? = nil,
         receiptPairing: ReceiptPairing? = nil,
         sessionStore: CredentialSessionStore = CredentialSessionStore(),
         redeemQRLogin: (@Sendable (URL, String) async throws -> QRLoginResponse)? = nil,
         events: @escaping @Sendable (SSESessionSnapshot) -> AsyncStream<EventStream.Event> = { EventStream.changes(snapshot: $0) },
         eventRetryDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        let backendURLStore = sessionStore.backendURLStore
        let receiptPairing = receiptPairing ?? ReceiptPairing(serverURL: { backendURLStore.currentEffectiveURL() })
        self.sessionStore = sessionStore
        self.receiptPairing = receiptPairing
        self.api = api ?? APIClient(receiptPairing: receiptPairing, sessionStore: sessionStore)
        self.redeemQRLogin = redeemQRLogin ?? QRLoginAPI().redeem
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
            prepareInitialAuth(features: serverFeatures)
            await finishInitialAuth(using: beginCapabilityRefresh(source: .initialAuth))
        case .verifiedLegacy(let features, let capabilities):
            prepareInitialAuth(features: nil)
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
            let keepFeatures = !changed && (previousOrigin.map { OriginMatcher.matches($0, url) } ?? true)
            prepareInitialAuth(features: keepFeatures ? serverFeatures : nil)
            scheduleCleanup(cleanup, reconnect: true)
            return true
        } catch {
            reportSessionStorageFailure(error)
            return false
        }
    }

    func login(user: String, password: String) async {
        sessionStorageError = nil
        let attempt = beginAuthAttempt()
        let origin = activeOrigin
        await resetTask?.value
        guard isCurrent(attempt), OriginMatcher.matches(origin, activeOrigin) else { return }
        let credentials: (actor: String, token: String)
        do {
            let result = try await api.login(user: user, password: password, on: origin)
            guard result.ok, !result.user.isEmpty,
                  let token = result.token, !token.isEmpty else { throw APIError.unauthorized }
            credentials = (actor: result.user, token: token)
        } catch {
            guard isCurrent(attempt), OriginMatcher.matches(origin, activeOrigin),
                  !APIError.isCancellation(error) else { return }
            if phase == .ready { notice = APIError.wrap(error) } else { phase = .failed(APIError.wrap(error)) }
            return
        }
        guard isCurrent(attempt), OriginMatcher.matches(origin, activeOrigin) else { return }
        let commit: LoginCommit
        do {
            commit = try commitLogin(origin: origin, actor: credentials.actor, token: credentials.token)
        } catch {
            reportSessionStorageFailure(error)
            return
        }
        await finishInitialAuth(using: commit.hydration)
        await commit.cleanup?.value
        guard attempt.id == authAttempt, sessionStore.currentSnapshot() == commit.session, !Task.isCancelled else { return }
        await pairReceiptsAfterLogin(user: user, password: password, server: commit.session.origin)
    }

    func signIn(with payload: QRLoginPayload) async throws {
        let attempt = beginAuthAttempt()
        let target = payload.origin
        await resetTask?.value
        guard isCurrent(attempt) else { throw CancellationError() }

        let probe: ServerFeatures
        do {
            probe = try await api.probeFeatures(on: target)
        } catch {
            guard isCurrent(attempt), !APIError.isCancellation(error) else { throw CancellationError() }
            throw QRLoginError.failed
        }
        guard isCurrent(attempt) else { throw CancellationError() }
        guard probe.supports(.qrLogin) else { throw QRLoginError.unsupported }
        guard probe.qrOrigin == target else { throw QRLoginError.originMismatch }

        let result: QRLoginResponse
        do {
            result = try await redeemQRLogin(target, payload.code)
        } catch {
            guard isCurrent(attempt), !APIError.isCancellation(error) else { throw CancellationError() }
            throw (error as? QRLoginError) ?? .failed
        }
        guard isCurrent(attempt) else { throw CancellationError() }
        guard result.ok, !result.user.isEmpty, !result.token.isEmpty else { throw QRLoginError.invalidCode }

        let commit: LoginCommit
        do {
            commit = try commitLogin(origin: target, actor: result.user, token: result.token, preloadedProbe: probe)
        } catch {
            sessionStorageError = .credentialStorage
            throw APIError.credentialStorage
        }
        await finishInitialAuth(using: commit.hydration)
        await commit.cleanup?.value
    }

    private func beginAuthAttempt() -> AuthAttempt {
        authAttempt += 1
        return AuthAttempt(id: authAttempt, session: sessionGeneration)
    }

    private func isCurrent(_ attempt: AuthAttempt) -> Bool {
        !Task.isCancelled && attempt.id == authAttempt && attempt.session == sessionGeneration
    }

    private func commitLogin(origin: URL, actor: String, token: String, preloadedProbe: ServerFeatures? = nil) throws -> LoginCommit {
        if retryInvalidation { try clearInvalidatedSession() }
        let oldSession = sessionStore.currentSnapshot()
        var stagedDevice: StoredReceiptDeviceToken?
        // Preserve the V2b receipt handoff across crashes. The authoritative
        // Keychain write still precedes publishing the replacement session.
        let committed = try sessionStore.commitAuthoritative(origin: origin, actor: actor, token: token) { replacement in
            stagedDevice = try receiptPairing.prepareForLogin(from: oldSession, to: replacement)
        }
        sessionGeneration += 1
        sessionStorageError = nil
        needsSessionRestore = false
        if rejectedLegacyBearer {
            retryMigrationCleanup = sessionStore.retryLegacyMigrationCleanup()
            rejectedLegacyBearer = false
        }
        backendURLString = committed.origin.absoluteString
        prepareInitialAuth(features: preloadedProbe ?? serverFeatures)
        let detached = stagedDevice.flatMap { receiptPairing.finishStagedDetachment($0) }
        let logout = oldSession.flatMap { old -> BoundSession? in
            let sameOrigin = OriginMatcher.matches(old.origin, committed.origin)
            guard !sameOrigin || (old.actor != committed.actor && old.token != committed.token) else { return nil }
            return old
        }
        let cleanupTask = logout != nil || detached != nil
            ? scheduleCleanup(.init(oldSession: logout, detachedDevice: detached)) : nil
        let hydration = beginCapabilityRefresh(source: .initialAuth, preloadedProbe: preloadedProbe)
        return LoginCommit(session: committed, hydration: hydration, cleanup: cleanupTask)
    }

    private func prepareInitialAuth(features: ServerFeatures?) {
        clearAuthorization(keeping: features)
        phase = .connecting
    }

    private func finishInitialAuth(using refresh: CapabilityRefresh?) async {
        guard let refresh, let fence = await refresh.task.value else { return }
        await finishInitialAuth(using: fence, refreshSnapshot: refresh.snapshot)
    }

    private func finishInitialAuth(using fence: Fence, refreshSnapshot: RefreshSnapshot? = nil) async {
        guard isCurrent(fence), matchesRefresh(refreshSnapshot) else { return }
        if !canViewIOC {
            phase = .ready
        } else if await loadDiscovery(failingOnTransient: true, refreshSnapshot: refreshSnapshot) == .loaded,
                  isCurrentDiscovery(fence.discovery), matchesRefresh(refreshSnapshot) {
            startEvents()
        }
        guard isCurrent(fence), matchesRefresh(refreshSnapshot) else { return }
        try? await exchangeDeviceToken(reason: .automatic)
    }

    /// Admins get a receipts device token from the same credentials, so they
    /// don't have to copy a pairing code. Any failure leaves the code flow.
    private func pairReceiptsAfterLogin(user: String, password: String, server: URL) async {
        guard !receiptsUseExchange, capabilities?.canUseReceipts == true, receiptPairing.status != .paired else { return }
        try? await receiptPairing.pair(username: user, password: password,
                                       deviceName: ReceiptPairing.deviceName, server: server)
    }

    func pairReceiptsByExchange() async throws {
        try await exchangeDeviceToken(reason: .manual)
    }

    @discardableResult
    func signInAgainForDeviceExchange() -> Bool {
        guard receiptPairing.requiresExchangeSignIn else { return false }
        // Use the same-origin handoff so reauthentication leaves the prior device
        // token and any unresolved rotation intact.
        return saveAndConnect(activeOrigin.absoluteString)
    }

    private func exchangeDeviceToken(reason: ReceiptPairing.ExchangeReason, refreshOnDenial: Bool = true) async throws {
        guard phase == .ready, receiptsUseExchange, let session = sessionStore.currentSnapshot(), let capabilities,
              capabilities.canUseReceipts || NativeBudgetGate.isEligible(enabled: nativeBudgetEnabled,
                                                                         features: serverFeatures, capabilities: capabilities)
        else { return }
        let previous = currentReceiptScope
        let budgetToken = receiptPairing.nativeBudgetCredential(for: session.origin, session: session)
        let reviewToken = receiptPairing.receiptReviewCredential(
            for: session.origin, session: session, enabled: receiptReviewEnabled
        )
        defer {
            if session == sessionStore.currentSnapshot() {
                if previous != currentReceiptScope { receiptAccessGeneration += 1 }
                if let budgetToken, budgetToken != receiptPairing.nativeBudgetCredential(for: session.origin, session: session) {
                    closeBudget()
                }
                if reviewToken != receiptPairing.receiptReviewCredential(
                    for: session.origin, session: session, enabled: receiptReviewEnabled
                ) {
                    closeReceiptReview()
                }
            }
        }
        do {
            try await receiptPairing.exchange(session: session, capabilities: capabilities, deviceName: ReceiptPairing.deviceName,
                                              nativeBudgetEnabled: nativeBudgetEnabled,
                                              receiptReviewEnabled: receiptReviewEnabled, reason: reason)
        } catch DeviceExchangeError.http(403, "budget_forbidden") {
            guard session == sessionStore.currentSnapshot(), !Task.isCancelled else { throw CancellationError() }
            if refreshOnDenial { reportDenial() }
            throw DevicePairingError.receipts(.forbidden)
        }
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
        // Cancel in-flight sign-in even if local persistence prevents the reset.
        authAttempt += 1
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
        guard !Task.isCancelled, let refresh = beginCapabilityRefresh(source: source) else { return nil }
        return await refresh.task.value
    }

    private func beginCapabilityRefresh(source: RefreshSource, preloadedProbe: ServerFeatures? = nil) -> CapabilityRefresh? {
        let expectedPhase = phase
        guard expectedPhase == (source == .initialAuth ? .connecting : .ready)
                || (source == .foreground && expectedPhase == .needsAuth) else { return nil }
        // A denial needs an answer requested after the rejection. Explicit
        // refreshes own their follow-up work, so only like denials can share it.
        if let active = activeCapabilitiesRefresh, active.snapshot == currentRefreshSnapshot,
           source == .denial, active.source == .denial {
            return active
        }
        cancelCapabilityRefresh()
        let snapshot = currentRefreshSnapshot
        let task = Task { [weak self] in
            await self?.performCapabilityRefresh(source: source, snapshot: snapshot, phase: expectedPhase,
                                                 preloadedProbe: preloadedProbe)
        }
        let refresh = CapabilityRefresh(source: source, snapshot: snapshot, task: task)
        activeCapabilitiesRefresh = refresh
        return refresh
    }

    private func performCapabilityRefresh(source: RefreshSource, snapshot: RefreshSnapshot, phase expectedPhase: Phase,
                                          preloadedProbe: ServerFeatures?) async -> Fence? {
        defer {
            if activeCapabilitiesRefresh?.snapshot == snapshot { activeCapabilitiesRefresh = nil }
        }
        guard isCurrent(snapshot, phase: expectedPhase) else { return nil }
        let features: ServerFeatures
        do {
            if let preloadedProbe {
                features = preloadedProbe
            } else {
                features = try await api.probeFeatures(on: snapshot.origin)
            }
        } catch {
            if isCurrent(snapshot, phase: expectedPhase), source == .initialAuth, !APIError.isCancellation(error) {
                phase = .failed(APIError.wrap(error))
            }
            return nil
        }
        guard isCurrent(snapshot, phase: expectedPhase) else { return nil }
        // A confirmed feature rollback is enough to stop sending exchanged bearers,
        // even if the capability request fails or stays in flight.
        if !features.supports(.deviceExchange) { updateReceiptPairing(features: features, capabilities: nil) }
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
                narrowPublishedFeatures(probed: features)
                if phase == .connecting { phase = .failed(failure) }
            }
            return nil
        }
    }

    private func narrowPublishedFeatures(probed: ServerFeatures) {
        guard let published = serverFeatures else { return }
        let features = published.features.intersection(probed.features)
        let narrowed = ServerFeatures(
            authContract: min(published.authContract, probed.authContract),
            features: features,
            qrOrigin: features.contains(.qrLogin) && published.qrOrigin == probed.qrOrigin ? published.qrOrigin : nil,
            isLegacy: published.isLegacy || probed.isLegacy
        )
        authorization = (narrowed, capabilities)
        if calendarAPI == nil { closeAgenda() }
        if budgetAPI == nil { closeBudget() }
    }

    private func publishAuthorization(features: ServerFeatures?, capabilities published: Capabilities?) {
        if capabilities != published { capabilitiesGeneration += 1 }
        if capabilities?.canUseReceipts == true, published?.canUseReceipts != true {
            receiptAccessGeneration += 1
        }
        authorization = (features, published)
        receiptPairing.setUnauthenticatedOrigin(published?.isAuthOff == true ? activeOrigin : nil)
        updateReceiptPairing(features: published == nil ? nil : features, capabilities: published)
        if published != nil { receiptPairing.refreshStatus() }
        if calendarAPI == nil { closeAgenda() }
        if budgetAPI == nil { closeBudget() }
        if receiptReviewAPI == nil { closeReceiptReview() }
        else { activeReceiptReviewStore?.updateMatchAccess() }
        applyIOCGrant(published?.canViewIOC == true)
        openReceiptFlow?.updateMatchAccess()
    }

    private func updateReceiptPairing(features: ServerFeatures?, capabilities: Capabilities?) {
        let previous = currentReceiptScope
        receiptPairing.setServerFeatures(features, capabilities: capabilities)
        if previous != currentReceiptScope { receiptAccessGeneration += 1 }
        if budgetAPI == nil { closeBudget() }
        if receiptReviewAPI == nil { closeReceiptReview() }
        else { activeReceiptReviewStore?.updateMatchAccess() }
    }

    private func handleReceiptFailure(_ error: ReceiptError, scope: ReceiptSessionScope) {
        guard scope == currentReceiptScope else { return }
        handleDeviceFailure(error, used: receiptPairing.credential(for: scope.origin))
    }

    private func handleDeviceFailure(_ error: ReceiptError, used: StoredReceiptDeviceToken?) {
        if error.isAccessDenial { closeReceiptReview() }
        let reason: ReceiptPairing.ExchangeReason
        switch error {
        case .forbidden:
            notice = .forbidden
            reason = .ceilingExpansion
        case .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken:
            guard let used else { return }
            let code: String
            switch error {
            case .expiredDeviceToken: code = "device_token_expired"
            case .revokedDeviceToken: code = "device_token_revoked"
            default: code = "device_token_invalid"
            }
            guard let rejection = receiptPairing.handleTokenRejection(used, status: 401, code: code) else { return }
            if budgetAPI == nil { closeBudget() }
            receiptAccessGeneration += 1
            switch rejection {
            case .retired: reason = .retired
            case .rollback:
                _ = beginCapabilityRefresh(source: .denial)
                return
            }
        default:
            return
        }
        guard let refresh = beginCapabilityRefresh(source: .denial) else { return }
        Task { [weak self] in
            guard let fence = await refresh.task.value, let self, isCurrent(fence),
                  matchesRefresh(refresh.snapshot) else { return }
            try? await exchangeDeviceToken(reason: reason, refreshOnDenial: false)
        }
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
        guard let refresh = beginCapabilityRefresh(source: .foreground) else { return }
        let lifecycle = lifecycleGeneration
        Task { [weak self] in
            guard let fence = await refresh.task.value, let self, isCurrent(fence),
                  lifecycle == lifecycleGeneration else { return }
            if canViewIOC { startEvents() }
            try? await exchangeDeviceToken(reason: .refresh)
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
        guard let refresh = beginCapabilityRefresh(source: .userPull), let fence = await refresh.task.value,
              isCurrent(fence), matchesRefresh(refresh.snapshot) else { return }
        if !canViewIOC {
            try? await exchangeDeviceToken(reason: .refresh)
            return
        }
        guard await loadDiscovery() == .loaded, isCurrentDiscovery(fence.discovery) else { return }
        switch eventStage {
        case nil, .backingOff:
            startEvents(after: fence.discovery)
        case .opening(let openingFence) where openingFence != currentFence:
            startEvents(after: fence.discovery)
        case .opening, .connected:
            break
        }
        guard isCurrent(fence), matchesRefresh(refresh.snapshot) else { return }
        try? await exchangeDeviceToken(reason: .refresh)
    }

    @discardableResult
    func loadDiscovery(failingOnTransient: Bool = false) async -> DiscoveryOutcome {
        await loadDiscovery(failingOnTransient: failingOnTransient, refreshSnapshot: nil)
    }

    private func loadDiscovery(failingOnTransient: Bool, refreshSnapshot: RefreshSnapshot?) async -> DiscoveryOutcome {
        let fence = currentDiscoveryFence
        func isCurrentLoad() -> Bool {
            isCurrentDiscovery(fence) && matchesRefresh(refreshSnapshot)
        }
        guard isCurrentLoad() else { return .cancelledOrStale }
        do {
            let discovery = try await api.discovery()
            guard isCurrentLoad() else { return .cancelledOrStale }
            rooms = RoomGroup.group(discovery)
            summary = discovery.summary
            globals = discovery.globals
            klima = discovery.klima
            klimaState = discovery.klimaState
            if phase == .connecting { phase = .ready }
            return .loaded
        } catch {
            guard isCurrentLoad(), !APIError.isCancellation(error) else { return .cancelledOrStale }
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

    private func matchesRefresh(_ snapshot: RefreshSnapshot?) -> Bool {
        snapshot.map { $0 == currentRefreshSnapshot } ?? true
    }

    private func stopForIOCDenial() {
        clearIOC()
        phase = .ready
        reportDenial()
    }

    private func fail(_ error: APIError) {
        discoveryGeneration += 1
        stopEvents()
        closeBudget()
        closeReceiptReview()
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
