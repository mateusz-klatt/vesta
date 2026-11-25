import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ReceiptPairing {
    enum Status { case notPaired, paired, pairAgain }
    enum ExchangeReason { case automatic, manual, ceilingExpansion, retired }
    enum TokenRejection { case retired, rollback }

    private static let failedRevocationNotice: LocalizedStringResource =
        "Couldn't reach hestia. Remove this iPhone in hestia's device list."
    private static let newDeviceNotice: LocalizedStringResource = "This iPhone was paired as a new device."

    private(set) var status: Status = .notPaired
    private(set) var revocationNotice: LocalizedStringResource?
    /// Why the automatic pairing after login didn't pair this iPhone, when the
    /// user has to act on it.
    private(set) var pairingNotice: LocalizedStringResource?
    private(set) var requiresExchangeSignIn = false
    private(set) var showNewDeviceAlert = false
    private(set) var deviceLimit: DeviceExchangeLimit?
    private(set) var hasEvictedPendingRevocations = false
    private var isPairing = false
    private var isRevoking = false
    private var isRetryingPendingRevocations = false
    var isBusy: Bool { isPairing || isRevoking }

    private let api: any DevicePairingAPI
    private let store: any DeviceTokenStoring
    private let serverURL: @MainActor () -> URL
    private var sessionStore: CredentialSessionStore?
    private var unauthenticatedOrigin: URL?
    private var authorizationSession: BoundSession?
    private var publishedFeatures: ServerFeatures?
    private var publishedCapabilities: Capabilities?
    private var rollbackSession: BoundSession?
    private var exchangeAuthorizationRevision = 0
    private var pairingCancelled = false
    private var detachedRevocations: [StoredReceiptDeviceToken] = []

    init(api: any DevicePairingAPI = GeneratedDevicePairingAPI(),
         store: any DeviceTokenStoring = KeychainDeviceTokenStore(),
         serverURL: @escaping @MainActor () -> URL = { AppConfig.serverURL }) {
        self.api = api
        self.store = store
        self.serverURL = serverURL
        refreshDisplayedStatus()
        updateRevocationNotice()
    }

    func refreshStatus() {
        if !isBusy, let session = sessionStore?.currentSnapshot(), supportsExchange(in: session) {
            do {
                try reconcileRotation(for: session)
                try restoreDeviceLimit(for: session)
            } catch {
                pairingNotice = DevicePairingError.storage.message
            }
        }
        schedulePendingRevocationRetry()
        refreshDisplayedStatus()
    }

    func retryInterruptedDetach() {
        schedulePendingRevocationRetry(interruptedOnly: true)
    }

    private func refreshDisplayedStatus() {
        guard !isBusy, status != .pairAgain else { return }
        status = credential(for: server) == nil ? .notPaired : .paired
    }

    func setServerFeatures(_ features: ServerFeatures?, capabilities: Capabilities? = nil) {
        let session = sessionStore?.currentSnapshot()
        if authorizationSession != session || publishedFeatures != features || publishedCapabilities != capabilities {
            exchangeAuthorizationRevision += 1
        }
        if authorizationSession != session {
            deviceLimit = nil
            pairingNotice = nil
            requiresExchangeSignIn = false
            showNewDeviceAlert = false
            rollbackSession = nil
            status = .notPaired
        }
        authorizationSession = session
        publishedFeatures = features
        publishedCapabilities = capabilities
        if capabilities != nil, features?.supports(.deviceExchange) == true { rollbackSession = nil }
        if let session, let features, !features.supports(.deviceExchange) {
            if deviceLimit != nil { pairingNotice = nil }
            deviceLimit = nil
            requiresExchangeSignIn = false
            showNewDeviceAlert = false
            do {
                if let active = try store.load(), active.provenance == .exchanged, isBound(active, to: session) {
                    try moveToRollbackQuarantine(active)
                    status = .pairAgain
                }
            } catch {
                pairingNotice = DevicePairingError.storage.message
            }
        }
        refreshDisplayedStatus()
    }

    func dismissNewDeviceAlert() {
        showNewDeviceAlert = false
        if pairingNotice?.key == Self.newDeviceNotice.key { pairingNotice = nil }
    }

    func bindSessionStore(_ store: CredentialSessionStore) {
        sessionStore = store
        refreshDisplayedStatus()
    }

    func setUnauthenticatedOrigin(_ origin: URL?) {
        unauthenticatedOrigin = origin
        refreshDisplayedStatus()
    }

    func credential(for server: URL) -> StoredReceiptDeviceToken? {
        credential(for: server, session: sessionStore?.currentSnapshot())
    }

    func credential(for server: URL, session: BoundSession?) -> StoredReceiptDeviceToken? {
        guard let token = activeCredential(for: server, session: session) else { return nil }
        if token.provenance == .exchanged {
            guard publishedCapabilities?.canUseReceipts != false,
                  token.issuedPermissions?.contains(Permission.budgetReceiptsAdd.rawValue) == true else { return nil }
        } else if let session, supportsExchange(in: session), let publishedCapabilities {
            guard canUseOwnReceipts(publishedCapabilities) else { return nil }
        }
        return token
    }

    private func activeCredential(for server: URL, session: BoundSession?) -> StoredReceiptDeviceToken? {
        guard !isRevoking, status != .pairAgain, OriginMatcher.matches(server, self.server),
              let token = try? store.load(), OriginMatcher.matches(server, token.server),
              let protected = try? protectsFromUse(token), !protected else { return nil }
        if let sessionStore, sessionStore.currentSnapshot() != session { return nil }
        if sessionStore == nil, session == nil {
            guard token.provenance != .exchanged, token.sessionCommitID == nil else { return nil }
            return token
        }
        if token.provenance == .exchanged {
            guard let session, supportsExchange(in: session) else { return nil }
        }
        return isBound(token, to: session) ? token : nil
    }

    func nativeBudgetCredential(for origin: URL, session: BoundSession?) -> StoredReceiptDeviceToken? {
        guard let session, supportsExchange(in: session),
              NativeBudgetGate.isEligible(enabled: true, features: publishedFeatures, capabilities: publishedCapabilities),
              let token = activeCredential(for: origin, session: session),
              NativeBudgetGate.allowsDevice(token, origin: origin, actor: session.actor) else { return nil }
        return token
    }

    private func isBound(_ token: StoredReceiptDeviceToken, to session: BoundSession?) -> Bool {
        if let session {
            guard OriginMatcher.matches(token.server, session.origin) else { return false }
        } else {
            guard let unauthenticatedOrigin, OriginMatcher.matches(token.server, unauthenticatedOrigin) else { return false }
        }
        switch token.provenance {
        case .legacyCodeRedeem:
            if let session { return session.commitID.map(token.isCodeBound(to:)) ?? false }
            return token.sessionCommitID == nil
        case .legacyPasswordLogin, .legacyMigrated1x:
            return token.actor == session?.actor
        case .exchanged:
            return session?.actor != nil && token.actor == session?.actor && token.ownerKey?.isEmpty == false
        }
    }

    /// Called only after the old backend bearer has verified at its saved origin.
    func bindLegacyCredential(origin: URL, actor: String?) throws {
        guard let active = try store.load(), active.provenance == .legacyMigrated1x,
              active.actor == nil, let actor, OriginMatcher.matches(origin, active.server) else { return }
        try store.save(active.withScope(actor: actor))
    }

    /// A same-origin reset saves the previously verified actor before clearing auth.
    /// The credential itself still has no verified actor or owner.
    func prepareCodeReauthentication(from session: BoundSession?) throws {
        guard let session, let actor = session.actor, let commitID = session.commitID,
              let active = try store.load(), active.provenance == .legacyCodeRedeem,
              isBound(active, to: session) else { return }
        try store.removePendingRevocation(active)
        let handoff = ReceiptCodeSessionHandoff(actor: actor, previousCommitID: commitID)
        try store.save(active.withScope(actor: nil, sessionCommitID: commitID, codeSessionHandoff: handoff))
    }

    func prepareForLogin(from old: BoundSession?, to new: BoundSession) throws -> StoredReceiptDeviceToken? {
        guard let active = try store.load() else { return nil }
        let alreadyStaged = try store.loadPendingRevocations().contains(where: active.matchesBearer)
        if alreadyStaged, !isBound(active, to: old), try !protectsFromUse(active) {
            // Finish a previous reset before the replacement session can make
            // the pending credential usable again (for example for the same actor).
            return try finishActiveDetachment(active)
        }
        if active.provenance == .legacyCodeRedeem, try retainCodeCredential(active, from: old, to: new) { return nil }

        let sessionChanged = old.map { !OriginMatcher.matches($0.origin, new.origin) || $0.actor != new.actor } ?? false
        let deviceOriginChanged = !OriginMatcher.matches(active.server, new.origin)
        let deviceActorChanged = active.actor.map { $0 != new.actor } ?? false
        guard sessionChanged || deviceOriginChanged || deviceActorChanged || active.provenance == .legacyCodeRedeem
        else { return nil }
        return try stageActiveDetachment(active)
    }

    private func retainCodeCredential(_ active: StoredReceiptDeviceToken, from old: BoundSession?, to new: BoundSession) throws -> Bool {
        guard let actor = new.actor, let newCommitID = new.commitID,
              OriginMatcher.matches(active.server, new.origin) else { return false }
        let previousCommitID: UUID
        if let old {
            guard old.actor == actor, let oldCommitID = old.commitID, isBound(active, to: old) else { return false }
            previousCommitID = oldCommitID
        } else {
            guard let handoff = active.codeSessionHandoff, handoff.actor == actor else { return false }
            previousCommitID = handoff.previousCommitID
        }
        // Both IDs belong to the same verified actor and origin. Keeping the old
        // binding usable lets a failed authoritative write leave the old session intact.
        try store.removePendingRevocation(active)
        let handoff = ReceiptCodeSessionHandoff(actor: actor, previousCommitID: previousCommitID)
        try store.save(active.withScope(actor: nil, sessionCommitID: newCommitID, codeSessionHandoff: handoff))
        return true
    }

    func currentActiveToken() throws -> StoredReceiptDeviceToken? {
        try store.load()
    }

    /// Save the full issuing credential for exact revocation before clearing
    /// the active slot. A crash after either operation leaves a copy for cleanup.
    func detachActive(_ expected: StoredReceiptDeviceToken?) throws -> StoredReceiptDeviceToken? {
        try finishActiveDetachment(stageActiveDetachment(expected))
    }

    func stageActiveDetachment(_ expected: StoredReceiptDeviceToken?) throws -> StoredReceiptDeviceToken? {
        guard let expected, try store.load() == expected else { return nil }
        // A scoped journal already holds this bearer. A session switch must not
        // revoke proof that may be needed to recover a lost exchange response.
        guard try !protectsFromUse(expected) else { return nil }
        if expected.provenance == .exchanged, exchangeKnownUnavailable(at: expected.server) {
            try moveToRollbackQuarantine(expected)
            return nil
        }
        try store.addPendingRevocation(expected, preservingExisting: true)
        return expected
    }

    func finishStagedDetachment(_ expected: StoredReceiptDeviceToken?) -> StoredReceiptDeviceToken? {
        do {
            return try finishActiveDetachment(expected)
        } catch {
            // The full credential is already in the pending list. A later retry
            // can clear the duplicate active item and revoke it.
            revocationNotice = DevicePairingError.storage.message
            return nil
        }
    }

    private func finishActiveDetachment(_ expected: StoredReceiptDeviceToken?) throws -> StoredReceiptDeviceToken? {
        pairingCancelled = true
        status = .notPaired
        pairingNotice = nil
        requiresExchangeSignIn = false
        showNewDeviceAlert = false
        do {
            guard let expected, try !protectsFromUse(expected) else { return nil }
            if try store.load() == expected { try store.clear() }
            return expected
        } catch {
            refreshDisplayedStatus()
            throw DevicePairingError.storage
        }
    }

    /// hestia rotates the token of an unrevoked device with the same name, so
    /// the name stays stable for this install and differs between two iPhones.
    static var deviceName: String {
        get throws {
            let suffix = try KeychainDeviceTokenStore().deviceNameSuffix()
            return "\(UIDevice.current.model) \(suffix.prefix(12))"
        }
    }

    /// The backend pairing requests go to right now.
    var server: URL { sessionStore?.currentSnapshot()?.origin ?? unauthenticatedOrigin ?? serverURL() }

    func pair(code: ReceiptPairingCode, deviceName: String) async throws {
        try await issue(provenance: .legacyCodeRedeem) { api, server in
            try await api.redeem(code: code, deviceName: deviceName, server: server)
        }
    }

    /// Pairs right after an admin login. The password is used for this one
    /// request and never stored. It only goes over HTTPS, and only to the
    /// server the login used; otherwise this does nothing.
    func pair(username: String, password: String, deviceName: String, server expected: URL) async throws {
        guard expected.scheme == "https" else { return }
        let session = sessionStore?.currentSnapshot()
        let actor = sessionStore == nil ? username : session?.actor
        guard actor != nil else { return }
        // No identity was recorded in 1.x. A password login without its old
        // verified bearer cannot safely claim or rotate that device slot.
        if let active = try store.load(), active.provenance == .legacyMigrated1x, active.actor == nil,
           OriginMatcher.matches(active.server, expected) { return }
        pairingNotice = nil
        do {
            try await issue(provenance: .legacyPasswordLogin, actor: actor, expecting: expected) { api, server in
                try await api.login(username: username, password: password, deviceName: deviceName, server: server)
            }
        } catch DevicePairingError.deviceLimit {
            // A late answer must not bring the notice back after sign-out or a server change.
            if !pairingCancelled, OriginMatcher.matches(expected, server), session == sessionStore?.currentSnapshot() {
                pairingNotice = DevicePairingError.deviceLimit.message
            }
            throw DevicePairingError.deviceLimit
        }
    }

    private func issue(
        provenance: DeviceTokenProvenance,
        actor: String? = nil,
        expecting expected: URL? = nil,
        _ request: (any DevicePairingAPI, URL) async throws -> ReceiptDeviceToken
    ) async throws {
        guard !isBusy, status != .paired else { return }
        let server = self.server
        let session = sessionStore?.currentSnapshot()
        let unauthenticatedOrigin = self.unauthenticatedOrigin
        guard sessionStore == nil || session?.commitID != nil || unauthenticatedOrigin != nil else { return }
        if let session, authorizationSession == session, publishedFeatures?.supports(.deviceExchange) == true { return }
        if let expected, !OriginMatcher.matches(expected, server) { return }
        isPairing = true
        pairingCancelled = false
        defer {
            isPairing = false
            if status == .paired { schedulePendingRevocationRetry() }
        }
        let token: ReceiptDeviceToken
        do {
            token = try await request(api, server)
        } catch let error as DevicePairingError {
            throw error
        } catch {
            throw DevicePairingError.redeemFailed
        }
        let stored = StoredReceiptDeviceToken(server: server, provenance: provenance, actor: actor,
                                              sessionCommitID: provenance == .legacyCodeRedeem ? session?.commitID : nil,
                                              credential: token)
        guard !pairingCancelled, !Task.isCancelled, OriginMatcher.matches(server, self.server),
              session == sessionStore?.currentSnapshot(), unauthenticatedOrigin == self.unauthenticatedOrigin else {
            try await revokeDetached(stored)
            throw CancellationError()
        }
        do {
            if let old = try store.load(), !old.matchesDevice(stored), try !protectsFromUse(old) {
                if old.provenance == .exchanged, exchangeKnownUnavailable(at: old.server) {
                    try moveToRollbackQuarantine(old)
                } else {
                    try store.addPendingRevocation(old, preservingExisting: true)
                }
            }
            try store.save(stored)
            status = .paired
            pairingNotice = nil
        } catch {
            try await revokeDetached(stored)
            throw DevicePairingError.storage
        }
    }

    func unpair() async throws {
        pairingCancelled = true
        guard !isRevoking else { return }
        isRevoking = true
        defer { isRevoking = false }
        do {
            if let detached = try detachActive(try currentActiveToken()) {
                try await revokeDetached(detached)
            }
        } catch {
            throw DevicePairingError.storage
        }
    }

    func revokeDetached(_ token: StoredReceiptDeviceToken) async throws {
        if let active = try? store.load(), active.matchesBearer(token) { return }
        guard try !protectsFromUse(token) else { return }
        if token.provenance == .exchanged, exchangeKnownUnavailable(at: token.server) {
            try moveToRollbackQuarantine(token)
            try store.removePendingRevocation(token)
            updateRevocationNotice()
            return
        }
        guard !detachedRevocations.contains(where: { $0.matchesBearer(token) }) else { return }
        detachedRevocations.append(token)
        defer { detachedRevocations.removeAll { $0 == token } }
        do {
            try await api.revoke(token.credential, server: token.server)
        } catch {
            if !Self.revocationCompleted(error) {
                try store.addPendingRevocation(token)
                updateRevocationNotice()
                return
            }
        }
        try store.removePendingRevocation(token)
        updateRevocationNotice()
    }

    private func schedulePendingRevocationRetry(interruptedOnly: Bool = false) {
        guard !isRetryingPendingRevocations, !isPairing,
              var pending = pendingRevocationsRequiringCleanup() else { return }
        guard !pending.isEmpty else {
            updateRevocationNotice()
            return
        }
        if interruptedOnly {
            guard let active = try? store.load(), sessionStore != nil,
                  !isBound(active, to: sessionStore?.currentSnapshot()) else { return }
            pending = pending.filter { $0.matchesBearer(active) }
        }
        guard !pending.isEmpty else { return }
        revocationNotice = Self.failedRevocationNotice
        isRetryingPendingRevocations = true
        Task { [weak self] in
            await self?.retryPendingRevocations(pending)
        }
    }

    private func retryPendingRevocations(_ pending: [StoredReceiptDeviceToken]) async {
        defer { isRetryingPendingRevocations = false }
        for token in pending {
            do {
                guard try store.loadPendingRevocations().contains(token), try !protectsFromUse(token) else { continue }
                if let active = try store.load(), active.matchesDevice(token) {
                    // A staged detach must leave the old credential alone while its
                    // session is still authoritative (for example after a failed reset).
                    guard active.matchesBearer(token), sessionStore != nil,
                          !isBound(active, to: sessionStore?.currentSnapshot()) else { continue }
                    guard try finishActiveDetachment(active) != nil else { continue }
                }
                try await revokeDetached(token)
            } catch {
                revocationNotice = DevicePairingError.storage.message
                return
            }
        }
        updateRevocationNotice()
    }

    private func updateRevocationNotice() {
        guard let pending = pendingRevocationsRequiringCleanup() else { return }
        if let evicted = try? store.hasPendingRevocationOverflow() { hasEvictedPendingRevocations = evicted }
        revocationNotice = pending.isEmpty && !hasEvictedPendingRevocations ? nil : Self.failedRevocationNotice
    }

    private func pendingRevocationsRequiringCleanup() -> [StoredReceiptDeviceToken]? {
        guard let pending = try? store.loadPendingRevocations() else { return nil }
        guard !pending.isEmpty, let sessionStore, let active = try? store.load(),
              isBound(active, to: sessionStore.currentSnapshot()) else { return pending }
        // Staging is durable before the session write. Until the old binding is
        // gone, its active credential still belongs to the current session.
        return pending.filter { !active.matchesBearer($0) }
    }

    private static func revocationCompleted(_ error: any Error) -> Bool {
        if case .http(401, let code) = error as? DeviceRevocationError {
            return code == "device_token_expired" || code == "device_token_revoked"
        }
        let receiptError = ReceiptError.wrap(error)
        return receiptError == .expiredDeviceToken || receiptError == .revokedDeviceToken
    }

    func invalidate(_ used: StoredReceiptDeviceToken) {
        _ = handleTokenRejection(used, status: 401, code: "device_token_revoked")
    }
}

extension ReceiptPairing {
    func exchange(session: BoundSession, capabilities: Capabilities, deviceName: String,
                  nativeBudgetEnabled: Bool = false, reason: ExchangeReason = .automatic) async throws {
        guard !isBusy, let actor = session.actor, !actor.isEmpty,
              sessionStore?.currentSnapshot() == session, supportsExchange(in: session),
              capabilities.user == nil || capabilities.user == actor,
              publishedCapabilities.map({ $0 == capabilities }) ?? true else { return }
        let budgetEligible = NativeBudgetGate.isEligible(enabled: nativeBudgetEnabled, features: publishedFeatures,
                                                         capabilities: capabilities)
        guard capabilities.canUseReceipts || budgetEligible else { return }

        try reconcileRotation(for: session)
        try restoreDeviceLimit(for: session)
        guard deviceLimit == nil || reason == .manual || reason == .retired else { return }

        let active = try store.load()
        let journal = try matchingRotation(for: session, active: active)
        let hasUnattributedActive = active.map {
            $0.provenance == .legacyMigrated1x && $0.actor == nil && OriginMatcher.matches($0.server, session.origin)
        } ?? false
        let hasOwnReceipts = canUseOwnReceipts(capabilities)
        let selfSlotEligible = hasOwnReceipts || budgetEligible
        let knownOwner = hasOwnReceipts || (budgetEligible && !capabilities.canUseReceipts)
        let eligibleActive = active.flatMap { token in
            isBound(token, to: session) && (token.provenance == .exchanged || selfSlotEligible) ? token : nil
        }
        let prior: StoredReceiptDeviceToken?
        if reason == .manual, hasUnattributedActive {
            prior = nil
        } else if let journal {
            prior = journal.priorToken
        } else if reason == .retired {
            prior = nil
        } else if let eligibleActive {
            prior = eligibleActive
        } else {
            prior = try store.loadRollbackQuarantine().last { isBound($0, to: session) }
        }
        if journal == nil, let eligibleActive, eligibleActive.provenance == .exchanged, reason == .automatic,
           !capabilities.canUseReceipts || eligibleActive.issuedPermissions?.contains(Permission.budgetReceiptsAdd.rawValue) == true,
           !budgetEligible || eligibleActive.issuedPermissions?.contains(Permission.budgetView.rawValue) == true { return }
        if journal == nil, reason == .ceilingExpansion {
            guard let prior else { return }
            if prior.provenance == .exchanged {
                let ceiling = Set((prior.lastUsableCeiling ?? []).compactMap(Permission.init(rawValue:)))
                guard !capabilities.effectiveDeviceEligiblePermissions.isSubset(of: ceiling) else { return }
            }
        }
        if hasUnattributedActive, prior == nil, reason != .manual {
            // Wait for an explicit pairing tap before replacing a record with no actor binding.
            return
        }

        let revision = exchangeAuthorizationRevision
        isPairing = true
        pairingCancelled = false
        defer {
            isPairing = false
            refreshDisplayedStatus()
        }
        pairingNotice = nil
        requiresExchangeSignIn = false

        if let prior {
            let record = journal ?? RotationJournalRecord(state: .intent, server: session.origin,
                capturedActor: actor, expectedOwnerKey: prior.ownerKey, slotTokenID: prior.credential.tokenID,
                priorToken: prior)
            let isRetry = record.state == .outcomeUnknown
            if !isRetry {
                try saveRotation(record)
                try saveRotation(record.transitioning(to: .sent))
            }

            let result: ExchangedDeviceToken
            do {
                result = try await api.exchange(session: session, deviceName: deviceName, priorToken: prior.credential)
            } catch {
                guard isCurrentExchange(session, revision: revision), try store.load() == active else {
                    try saveRotation(record.transitioning(to: .outcomeUnknown))
                    throw CancellationError()
                }
                if case .http(409, "device_token_prior_invalid") = error as? DeviceExchangeError {
                    // The server has explicitly rejected the proof. Keep its full
                    // bearer in hand for exact cleanup after a distinct fresh success.
                    try discardInvalidPrior(record)
                    try await issueFresh(session: session, actor: actor, deviceName: deviceName, isOwner: knownOwner,
                                         invalidPrior: prior, revision: revision, startingActive: store.load())
                    return
                }
                try preserveRotation(after: error, record: record, fromUnknown: isRetry)
                try reportExchangeError(error, session: session, actor: actor, deviceName: deviceName,
                                        prior: prior, isOwner: knownOwner && (prior.owner ?? actor) == actor)
                throw error
            }

            let replacement = storedExchange(result, server: session.origin)
            guard isCurrentExchange(session, revision: revision), try store.load() == active else {
                try saveRotation(record.transitioning(to: .outcomeUnknown))
                try quarantineUntrusted(replacement)
                throw CancellationError()
            }
            guard validReplacement(replacement, for: record) else {
                try quarantineUntrusted(replacement)
                if !isRetry { try removeRotation(record) }
                if isRetry { status = .pairAgain }
                throw invalidExchangeResponse()
            }
            let replaced = record.transitioning(to: .replaced, replacement: replacement)
            try saveRotation(replaced)
            try promoteRotation(replaced)
        } else {
            try await issueFresh(session: session, actor: actor, deviceName: deviceName, isOwner: knownOwner,
                                 invalidPrior: nil, revision: revision, startingActive: active)
        }
    }

    private func issueFresh(session: BoundSession, actor: String, deviceName: String, isOwner: Bool,
                            invalidPrior: StoredReceiptDeviceToken?, revision: Int,
                            startingActive: StoredReceiptDeviceToken?) async throws {
        let result: ExchangedDeviceToken
        do {
            result = try await api.exchange(session: session, deviceName: deviceName, priorToken: nil)
        } catch {
            guard isCurrentExchange(session, revision: revision), try store.load() == startingActive else {
                throw CancellationError()
            }
            try reportExchangeError(error, session: session, actor: actor, deviceName: deviceName,
                                    prior: invalidPrior, isOwner: isOwner)
            throw error
        }
        let replacement = storedExchange(result, server: session.origin)
        guard isCurrentExchange(session, revision: revision), try store.load() == startingActive else {
            try quarantineUntrusted(replacement)
            throw CancellationError()
        }
        guard validExchange(replacement, actor: actor) else {
            try quarantineUntrusted(replacement)
            throw invalidExchangeResponse()
        }

        let old = invalidPrior ?? startingActive
        do {
            if let old, old.provenance == .legacyMigrated1x, old.actor == nil {
                // Keep the issuing bearer for exact-device recovery without associating it with this session.
                try quarantineUntrusted(old)
            }
            try store.save(replacement)
        } catch {
            try quarantineUntrusted(replacement)
            throw DevicePairingError.storage
        }
        status = .paired
        pairingNotice = invalidPrior == nil ? nil : Self.newDeviceNotice
        showNewDeviceAlert = invalidPrior != nil
        try clearDeviceLimit(for: session)
        if let old, !old.matchesDevice(replacement), try !protectsFromUse(old),
           invalidPrior != nil || isBound(old, to: session) {
            try store.addPendingRevocation(old, preservingExisting: true)
            try await revokeDetached(old)
        }
    }

    private func isCurrentExchange(_ session: BoundSession, revision: Int) -> Bool {
        !Task.isCancelled && !pairingCancelled && sessionStore?.currentSnapshot() == session
            && supportsExchange(in: session) && revision == exchangeAuthorizationRevision
    }

    private func canUseOwnReceipts(_ capabilities: Capabilities) -> Bool {
        capabilities.ownBudget?.canUseReceipts == true
            && capabilities.ownBudget?.permissions.contains(.budgetReceiptsAdd) == true
    }

    private func supportsExchange(in session: BoundSession) -> Bool {
        authorizationSession == session && rollbackSession != session && publishedFeatures?.supports(.deviceExchange) == true
    }

    private func exchangeKnownUnavailable(at origin: URL) -> Bool {
        guard let session = authorizationSession, OriginMatcher.matches(session.origin, origin),
              let publishedFeatures else { return false }
        return rollbackSession == session || !publishedFeatures.supports(.deviceExchange)
    }

    private func storedExchange(_ result: ExchangedDeviceToken, server: URL) -> StoredReceiptDeviceToken {
        let ceiling = Set(result.issuedPermissions.compactMap(Permission.init(rawValue:)))
            .intersection(Permission.deviceEligibleIDs).map(\.rawValue).sorted()
        return .init(server: server, provenance: .exchanged, actor: result.actor, owner: result.owner,
                     ownerKey: result.ownerKey, issuedPermissions: result.issuedPermissions,
                     lastUsableCeiling: ceiling, deviceScope: result.scope, credential: result.credential)
    }

    private func validExchange(_ token: StoredReceiptDeviceToken, actor: String) -> Bool {
        token.provenance == .exchanged && token.actor == actor && token.owner?.isEmpty == false
            && token.ownerKey?.isEmpty == false && !token.credential.tokenID.isEmpty && !token.credential.token.isEmpty
    }

    private func validReplacement(_ token: StoredReceiptDeviceToken, for record: RotationJournalRecord) -> Bool {
        guard validExchange(token, actor: record.capturedActor), OriginMatcher.matches(token.server, record.server),
              token.credential.tokenID == record.slotTokenID else { return false }
        if let expectedOwnerKey = record.expectedOwnerKey { return token.ownerKey == expectedOwnerKey }
        return token.actor == token.owner
    }

    private func invalidExchangeResponse() -> DevicePairingError {
        let error = APIError.unexpected("Invalid device exchange response")
        pairingNotice = error.title
        return .receipts(.api(error))
    }

    private func preserveRotation(after error: any Error, record: RotationJournalRecord, fromUnknown: Bool) throws {
        switch error as? DeviceExchangeError {
        case .invalidSession, .http(401, _), .http(403, "budget_forbidden"), .http(409, "device_token_limit_reached"):
            if !fromUnknown { try removeRotation(record) }
        default:
            try saveRotation(record.transitioning(to: .outcomeUnknown))
            status = .pairAgain
        }
    }

    private func reportExchangeError(_ error: any Error, session: BoundSession, actor: String, deviceName: String,
                                     prior: StoredReceiptDeviceToken?, isOwner: Bool) throws {
        switch error as? DeviceExchangeError {
        case .http(401, _):
            requiresExchangeSignIn = true
            pairingNotice = APIError.unauthorized.title
        case .http(403, "budget_forbidden"):
            pairingNotice = APIError.forbidden.message
        case .http(409, "device_token_limit_reached"):
            let limit = DeviceExchangeLimit(server: session.origin, actor: actor, deviceName: deviceName,
                                            tokenID: prior?.credential.tokenID ?? deviceLimit?.tokenID, isOwner: isOwner)
            var limits = try store.loadDeviceExchangeLimits()
            limits.removeAll { $0.matches(session) }
            limits.append(limit)
            try store.saveDeviceExchangeLimits(limits)
            showDeviceLimit(limit)
            throw DevicePairingError.deviceLimit
        default:
            pairingNotice = APIError.wrap(error).title
        }
    }

    private func showDeviceLimit(_ limit: DeviceExchangeLimit) {
        deviceLimit = limit
        pairingNotice = limit.isOwner
            ? "hestia already has 5 paired devices. Remove one in hestia’s device list."
            : "hestia already has 5 paired devices. Ask the ledger owner to remove one."
    }

    private func restoreDeviceLimit(for session: BoundSession) throws {
        if let limit = try store.loadDeviceExchangeLimits().last(where: { $0.matches(session) }) {
            showDeviceLimit(limit)
        } else {
            deviceLimit = nil
        }
    }

    private func clearDeviceLimit(for session: BoundSession) throws {
        var limits = try store.loadDeviceExchangeLimits()
        let count = limits.count
        limits.removeAll { $0.matches(session) }
        if count != limits.count { try store.saveDeviceExchangeLimits(limits) }
        deviceLimit = nil
    }

    private func matchingRotation(for session: BoundSession, active: StoredReceiptDeviceToken?) throws -> RotationJournalRecord? {
        let quarantine = try store.loadRollbackQuarantine()
        return try store.loadRotationJournal().last { record in
            guard record.matchesSession(session), record.matchesPriorScope else { return false }
            if let active, active.matchesBearer(record.priorToken) || record.replacement.map(active.matchesBearer) == true {
                return true
            }
            if let active, isBound(active, to: session) { return false }
            // After a switch, another actor can occupy the physical active slot.
            // A sent journal independently holds the previous actor's quarantined slot.
            return record.state != .intent || quarantine.contains(where: record.priorToken.matchesBearer)
        }
    }

    private func reconcileRotation(for session: BoundSession) throws {
        guard let record = try matchingRotation(for: session, active: store.load()) else { return }
        switch record.state {
        case .intent:
            try removeRotation(record)
        case .sent:
            try saveRotation(record.transitioning(to: .outcomeUnknown))
            status = .pairAgain
        case .outcomeUnknown:
            status = .pairAgain
        case .replaced:
            try promoteRotation(record)
        }
    }

    private func protectsFromUse(_ token: StoredReceiptDeviceToken) throws -> Bool {
        try store.loadRotationJournal().contains {
            $0.state != .intent && $0.priorToken.matchesBearer(token) && $0.replacement?.matchesBearer(token) != true
        }
    }

    private func saveRotation(_ record: RotationJournalRecord) throws {
        var records = try store.loadRotationJournal()
        records.removeAll { $0.capturedActor == record.capturedActor && $0.priorToken.matchesBearer(record.priorToken) }
        records.append(record)
        try store.saveRotationJournal(records)
    }

    private func removeRotation(_ record: RotationJournalRecord) throws {
        var records = try store.loadRotationJournal()
        records.removeAll { $0.capturedActor == record.capturedActor && $0.priorToken.matchesBearer(record.priorToken) }
        try store.saveRotationJournal(records)
    }

    private func promoteRotation(_ record: RotationJournalRecord) throws {
        guard let replacement = record.replacement, validReplacement(replacement, for: record) else {
            throw DevicePairingError.storage
        }
        try store.save(replacement)
        status = .paired
        pairingNotice = nil
        requiresExchangeSignIn = false
        if let session = sessionStore?.currentSnapshot() { try clearDeviceLimit(for: session) }
        try removeSupersededRotations(after: record, replacement: replacement)
    }

    private func removeSupersededRotations(after record: RotationJournalRecord, replacement: StoredReceiptDeviceToken) throws {
        let journal = try store.loadRotationJournal()
        let remaining = journal.filter { candidate in
            guard candidate.capturedActor == record.capturedActor, OriginMatcher.matches(candidate.server, record.server) else { return true }
            if candidate.priorToken.matchesBearer(record.priorToken) { return false }
            guard candidate.state == .outcomeUnknown, candidate.matchesPriorScope else { return true }
            let sameLedger = candidate.expectedOwnerKey.map { $0 == replacement.ownerKey } ?? (replacement.actor == replacement.owner)
            return !sameLedger || candidate.priorToken.matchesBearer(replacement) ||
                candidate.replacement?.matchesBearer(replacement) == true
        }
        let rollback = try store.loadRollbackQuarantine()
        let retained = rollback.filter { token in
            guard token.actor == record.capturedActor, OriginMatcher.matches(token.server, record.server),
                  token.ownerKey == replacement.ownerKey, !token.matchesBearer(replacement) else { return true }
            return remaining.contains { token.matchesBearer($0.priorToken) || $0.replacement.map(token.matchesBearer) == true }
        }
        // Keep the replaced journal durable until both cleanup writes have succeeded. Recovery can replay either write.
        if retained != rollback { try store.saveRollbackQuarantine(retained) }
        if remaining != journal { try store.saveRotationJournal(remaining) }
    }

    private func discardInvalidPrior(_ record: RotationJournalRecord) throws {
        if let active = try store.load(), active.matchesBearer(record.priorToken) { try store.clear() }
        try removeRollbackToken(record.priorToken)
        try removeRotation(record)
        status = .pairAgain
    }

    private func moveToRollbackQuarantine(_ token: StoredReceiptDeviceToken) throws {
        var tokens = try store.loadRollbackQuarantine()
        if !tokens.contains(where: token.matchesBearer) {
            tokens.append(token)
            try store.saveRollbackQuarantine(tokens)
        }
        if let active = try store.load(), active.matchesBearer(token) { try store.clear() }
    }

    private func removeRollbackToken(_ token: StoredReceiptDeviceToken) throws {
        var tokens = try store.loadRollbackQuarantine()
        let count = tokens.count
        tokens.removeAll(where: token.matchesBearer)
        if count != tokens.count { try store.saveRollbackQuarantine(tokens) }
    }

    private func quarantineUntrusted(_ token: StoredReceiptDeviceToken) throws {
        var tokens = try store.loadUntrustedExchangeTokens()
        if tokens.contains(where: token.matchesBearer) { return }
        tokens.append(token)
        try store.saveUntrustedExchangeTokens(tokens)
    }

    func handleTokenRejection(_ used: StoredReceiptDeviceToken, status: Int, code: String?) -> TokenRejection? {
        guard status == 401, !isRevoking, (try? store.load()) == used else { return nil }
        do {
            switch code {
            case "device_token_expired", "device_token_revoked":
                guard try !protectsFromUse(used) else { return nil }
                try store.clear()
                self.status = .pairAgain
                return .retired
            case "device_token_invalid" where used.provenance == .exchanged:
                rollbackSession = sessionStore?.currentSnapshot()
                exchangeAuthorizationRevision += 1
                try moveToRollbackQuarantine(used)
                self.status = .pairAgain
                return .rollback
            default:
                return nil
            }
        } catch {
            self.status = .pairAgain
            pairingNotice = DevicePairingError.storage.message
            return nil
        }
    }
}
