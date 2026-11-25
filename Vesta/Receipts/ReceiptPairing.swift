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
        if let session {
            guard OriginMatcher.matches(server, session.origin) else { return nil }
        } else {
            guard let unauthenticatedOrigin, OriginMatcher.matches(server, unauthenticatedOrigin) else { return nil }
        }
        switch token.provenance {
        case .legacyCodeRedeem:
            if let session, session.commitID == nil { return nil }
            return token.sessionCommitID == session?.commitID ? token : nil
        case .legacyPasswordLogin, .legacyMigrated1x:
            return token.actor == session?.actor ? token : nil
        case .exchanged:
            // V4 will select exchanged tokens using an explicit owner key.
            return nil
        }
    }

    /// Called only after the old backend bearer has verified at its saved origin.
    func bindLegacyCredential(origin: URL, actor: String?) throws {
        guard let active = try store.load(), active.provenance == .legacyMigrated1x,
              active.actor == nil, let actor, OriginMatcher.matches(origin, active.server) else { return }
        try store.save(active.withScope(actor: actor))
    }

    func retainCodeCredential(from old: BoundSession, to new: BoundSession) throws {
        guard let actor = old.actor, actor == new.actor, OriginMatcher.matches(old.origin, new.origin),
              let oldCommitID = old.commitID, let newCommitID = new.commitID,
              let active = try store.load(), active.provenance == .legacyCodeRedeem,
              active.sessionCommitID == oldCommitID, OriginMatcher.matches(old.origin, active.server) else { return }
        try store.save(active.withScope(actor: nil, sessionCommitID: newCommitID))
    }

    func currentActiveToken() throws -> StoredReceiptDeviceToken? {
        try store.load()
    }

    /// Save the full issuing credential for exact revocation before clearing
    /// the active slot. A crash after either operation leaves a copy for cleanup.
    func detachActive(_ expected: StoredReceiptDeviceToken?) throws -> StoredReceiptDeviceToken? {
        pairingCancelled = true
        status = .notPaired
        pairingNotice = nil
        guard let expected, try store.load() == expected else { return nil }
        do {
            try store.addPendingRevocation(expected, preservingExisting: true)
            try store.clear()
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

    private func schedulePendingRevocationRetry() {
        guard !isRetryingPendingRevocations, !isPairing,
              let pending = try? store.loadPendingRevocations(), !pending.isEmpty else { return }
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
                // A failed detach can leave the same token in both slots.
                if let active = try store.load(), active.matchesDevice(token) { continue }
                try await revokeDetached(token)
            } catch { break }
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
