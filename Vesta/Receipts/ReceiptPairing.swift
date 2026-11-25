import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class ReceiptPairing {
    enum Status { case notPaired, paired, pairAgain }

    private static let failedRevocationNotice: LocalizedStringResource =
        "Couldn't reach hestia. Remove this iPhone in hestia's device list."

    private(set) var status: Status = .notPaired
    private(set) var revocationNotice: LocalizedStringResource?
    /// Why the automatic pairing after login didn't pair this iPhone, when the
    /// user has to act on it.
    private(set) var pairingNotice: LocalizedStringResource?
    private var isPairing = false
    private var isRevoking = false
    private var isRetryingPendingRevocations = false
    var isBusy: Bool { isPairing || isRevoking }

    private let api: any DevicePairingAPI
    private let store: any DeviceTokenStoring
    private let serverURL: @MainActor () -> URL
    private var sessionStore: CredentialSessionStore?
    private var unauthenticatedOrigin: URL?
    private var pairingCancelled = false
    private var detachedRevocations: [StoredReceiptDeviceToken] = []

    init(api: any DevicePairingAPI = GeneratedDevicePairingAPI(),
         store: any DeviceTokenStoring = KeychainDeviceTokenStore(),
         serverURL: @escaping @MainActor () -> URL = { AppConfig.serverURL }) {
        self.api = api
        self.store = store
        self.serverURL = serverURL
        refreshDisplayedStatus()
    }

    func refreshStatus() {
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
        guard !isRevoking, status != .pairAgain, OriginMatcher.matches(server, self.server),
              let token = try? store.load(), OriginMatcher.matches(server, token.server) else { return nil }
        if let sessionStore, sessionStore.currentSnapshot() != session { return nil }
        if sessionStore == nil, session == nil {
            guard token.provenance != .exchanged, token.sessionCommitID == nil else { return nil }
            return token
        }
        return isBound(token, to: session) ? token : nil
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
            // V4 will select exchanged tokens using an explicit owner key.
            return false
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
        if alreadyStaged, !isBound(active, to: old) {
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
        do {
            guard let expected else { return nil }
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
        "\(UIDevice.current.model) \(KeychainDeviceTokenStore().deviceNameSuffix().prefix(12))"
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
            if let old = try store.load(), !old.matchesDevice(stored) {
                try store.addPendingRevocation(old, preservingExisting: true)
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
        guard !detachedRevocations.contains(where: { $0.matchesBearer(token) }) else { return }
        detachedRevocations.append(token)
        defer { detachedRevocations.removeAll { $0 == token } }
        do {
            try await api.revoke(token.credential, server: token.server)
        } catch {
            if !Self.revocationCompleted(error) {
                try store.addPendingRevocation(token, preservingExisting: true)
                revocationNotice = Self.failedRevocationNotice
                return
            }
        }
        try store.removePendingRevocation(token)
        updateRevocationNotice()
    }

    private func schedulePendingRevocationRetry(interruptedOnly: Bool = false) {
        guard !isRetryingPendingRevocations, !isPairing,
              var pending = try? store.loadPendingRevocations() else { return }
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
                guard try store.loadPendingRevocations().contains(token) else { continue }
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
        guard let pending = try? store.loadPendingRevocations() else { return }
        revocationNotice = pending.isEmpty ? nil : Self.failedRevocationNotice
    }

    private static func revocationCompleted(_ error: any Error) -> Bool {
        switch ReceiptError.wrap(error) {
        case .pairAgain, .notFound, .disabled: true
        default: false
        }
    }

    func invalidate(_ used: StoredReceiptDeviceToken) {
        // A delayed 401 from an old request must leave a replacement token alone.
        guard !isRevoking, (try? store.load()) == used else { return }
        status = .pairAgain
        try? store.clear()
    }
}
