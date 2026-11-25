import Foundation
import os

struct AuthoritativeSessionRecord: Codable, Equatable, Sendable {
    let commitID: UUID
    let origin: URL
    let actor: String?
    let token: String

    var snapshot: BoundSession {
        BoundSession(origin: origin, actor: actor, token: token, commitID: commitID)
    }
}

struct BoundSession: Equatable, Sendable {
    let origin: URL
    let actor: String?
    let token: String
    let commitID: UUID?

    init(origin: URL, actor: String?, token: String, commitID: UUID? = nil) {
        self.origin = origin
        self.actor = actor
        self.token = token
        self.commitID = commitID
    }
}

enum CredentialSessionStoreError: Error {
    case invalidRecord
    case staleLegacyCandidate
}

/// AppState publishes on the main actor. Request clients synchronously capture the entire binding.
final class CredentialSessionStore: @unchecked Sendable {
    enum BootstrapState: Equatable, Sendable {
        case ready(retryCleanup: Bool)
        case signedOut(retryCleanup: Bool)
        case verifyLegacy(BoundSession)
    }

    let backendURLStore: BackendURLStore
    private let keychain: any SessionKeychain
    private let lock = OSAllocatedUnfairLock<BoundSession?>(initialState: nil)

    init(backendURLStore: BackendURLStore = .shared, keychain: any SessionKeychain = SystemSessionKeychain()) {
        self.backendURLStore = backendURLStore
        self.keychain = keychain
    }

    func currentSnapshot() -> BoundSession? { lock.withLock { $0 } }

    @MainActor
    func bootstrap() throws -> BootstrapState {
        let record = try loadAuthoritative()
        let migrated = try keychain.read(.legacyMigrated) != nil
        let override = backendURLStore.loadOverrideRecord()

        if let record {
            reconcile(record)
            // The verified record is already durable. Keep the session usable if only
            // the marker or legacy deletion needs to be retried on foreground.
            return .ready(retryCleanup: needsCleanupRetry(marked: migrated))
        }

        if override?.sessionCommitID != nil {
            // A linked override without its record is a signed-out session.
            // Persist the retirement marker before unlinking an override that still fences the raw bearer.
            if !migrated { try markLegacyMigrated() }
            backendURLStore.saveOverride(backendURLStore.currentEffectiveURL())
            discardSnapshot()
            return .signedOut(retryCleanup: needsCleanupRetry(marked: true))
        }

        if migrated {
            discardSnapshot()
            return .ready(retryCleanup: needsCleanupRetry(marked: true))
        }

        guard let legacy = try keychain.read(.legacy) else {
            discardSnapshot()
            return .ready(retryCleanup: false)
        }
        guard let override else {
            try finalizeLegacyMigration(marked: false)
            discardSnapshot()
            return .ready(retryCleanup: false)
        }
        return .verifyLegacy(try legacySnapshot(legacy, override: override))
    }

    /// A legacy bearer is kept private to verification on the saved origin until this commit.
    @MainActor
    @discardableResult
    func completeLegacyMigration(_ candidate: BoundSession, actor: String?) throws -> Bool {
        guard try loadAuthoritative() == nil, try keychain.read(.legacyMigrated) == nil,
              let override = backendURLStore.loadOverrideRecord(), override.sessionCommitID == nil,
              let data = try keychain.read(.legacy),
              try legacySnapshot(data, override: override) == candidate else {
            throw CredentialSessionStoreError.staleLegacyCandidate
        }

        try commitAuthoritative(origin: candidate.origin, actor: actor, token: candidate.token)
        return needsCleanupRetry(marked: false)
    }

    @MainActor
    @discardableResult
    func commitAuthoritative(origin: URL, actor: String?, token: String,
                             beforeWrite: (BoundSession) throws -> Void = { _ in }) throws -> BoundSession {
        guard let origin = BackendURLStore.canonicalize(origin.absoluteString), !token.isEmpty else {
            throw CredentialSessionStoreError.invalidRecord
        }
        let record = AuthoritativeSessionRecord(commitID: UUID(), origin: origin, actor: actor, token: token)
        try beforeWrite(record.snapshot)
        try keychain.write(JSONEncoder().encode(record), to: .authoritative)
        reconcile(record)
        return record.snapshot
    }

    /// Retry cleanup after committing a replacement or otherwise retiring the legacy bearer.
    @MainActor
    func retryLegacyMigrationCleanup() -> Bool {
        needsCleanupRetry()
    }

    /// Capture the old bearer, then clear the persisted session before changing the selected origin.
    @MainActor
    @discardableResult
    func clearAuthoritative(savingOverride newOrigin: URL? = nil,
                            beforeClear: (BoundSession?) throws -> Void = { _ in }) throws -> BoundSession? {
        let record = try loadAuthoritative()
        let migrated = try keychain.read(.legacyMigrated) != nil
        let override = backendURLStore.loadOverrideRecord()
        var oldSession = record?.snapshot
        if oldSession == nil, !migrated, let override, override.sessionCommitID == nil,
           let data = try keychain.read(.legacy) {
            oldSession = try legacySnapshot(data, override: override)
        }

        try beforeClear(oldSession)
        try finalizeLegacyMigration(marked: migrated)
        // Keep the current authoritative record intact if either preceding operation failed.
        if record != nil { try keychain.delete(.authoritative) }
        if let origin = newOrigin ?? record?.origin ?? override.flatMap({ URL(string: $0.urlString) }) {
            backendURLStore.saveOverride(origin)
        }
        discardSnapshot()
        return oldSession
    }

    @MainActor
    func discardSnapshot() { lock.withLock { $0 = nil } }

    private func loadAuthoritative() throws -> AuthoritativeSessionRecord? {
        guard let data = try keychain.read(.authoritative) else { return nil }
        let record = try JSONDecoder().decode(AuthoritativeSessionRecord.self, from: data)
        guard BackendURLStore.canonicalize(record.origin.absoluteString) == record.origin,
              !record.token.isEmpty else { throw CredentialSessionStoreError.invalidRecord }
        return record
    }

    private func legacySnapshot(_ data: Data, override: OverrideRecord) throws -> BoundSession {
        guard let origin = URL(string: override.urlString),
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw CredentialSessionStoreError.invalidRecord
        }
        return BoundSession(origin: origin, actor: nil, token: token)
    }

    @MainActor
    private func reconcile(_ record: AuthoritativeSessionRecord) {
        let override = OverrideRecord(urlString: record.origin.absoluteString, sessionCommitID: record.commitID)
        if backendURLStore.loadOverrideRecord() != override {
            backendURLStore.saveOverride(record.origin, sessionCommitID: record.commitID)
        }
        lock.withLock { $0 = record.snapshot }
    }

    private func finalizeLegacyMigration(marked migrated: Bool) throws {
        if !migrated { try markLegacyMigrated() }
        try keychain.delete(.legacy)
    }

    private func markLegacyMigrated() throws {
        try keychain.write(Data([1]), to: .legacyMigrated)
    }

    private func needsCleanupRetry(marked migrated: Bool? = nil) -> Bool {
        do {
            let marked = try migrated ?? (keychain.read(.legacyMigrated) != nil)
            try finalizeLegacyMigration(marked: marked)
            return false
        } catch {
            return true
        }
    }
}
