import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest
import os
@testable import Vesta

final class TestSessionKeychain: SessionKeychain, @unchecked Sendable {
    enum Mutation: Equatable, Sendable {
        case write(SessionKeychainAccount)
        case delete(SessionKeychainAccount)
    }

    private struct State {
        var items: [SessionKeychainAccount: Data] = [:]
        var locked = false
        var failNext: Mutation?
        var mutations: [Mutation] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var mutations: [Mutation] { lock.withLock { $0.mutations } }

    func setLocked(_ locked: Bool) { lock.withLock { $0.locked = locked } }

    func failNext(_ mutation: Mutation) { lock.withLock { $0.failNext = mutation } }

    func seed(_ data: Data, for account: SessionKeychainAccount) {
        lock.withLock { $0.items[account] = data }
    }

    func storedData(for account: SessionKeychainAccount) -> Data? { lock.withLock { $0.items[account] } }

    func read(_ account: SessionKeychainAccount) throws -> Data? {
        try lock.withLock {
            guard !$0.locked else { throw SessionKeychainError.locked }
            return $0.items[account]
        }
    }

    func write(_ data: Data, to account: SessionKeychainAccount) throws {
        try mutate(.write(account), data: data, account: account)
    }

    func delete(_ account: SessionKeychainAccount) throws {
        try mutate(.delete(account), data: nil, account: account)
    }

    private func mutate(_ mutation: Mutation, data: Data?, account: SessionKeychainAccount) throws {
        try lock.withLock {
            $0.mutations.append(mutation)
            guard !$0.locked else { throw SessionKeychainError.locked }
            if $0.failNext == mutation {
                $0.failNext = nil
                throw SessionKeychainError.writeFailed
            }
            $0.items[account] = data
        }
    }
}

/// Simulates a crash before the derived override reaches defaults, even though the Keychain write succeeded.
private final class InterruptedOverrideDefaults: UserDefaults, @unchecked Sendable {
    private let dropWrite = OSAllocatedUnfairLock(initialState: false)

    func dropNextOverrideWrite() { dropWrite.withLock { $0 = true } }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == BackendURLStore.userDefaultsKey {
            let shouldDrop = dropWrite.withLock { drop in
                defer { drop = false }
                return drop
            }
            if shouldDrop { return }
        }
        super.set(value, forKey: defaultName)
    }
}

private actor SessionCleanupTransport: ClientTransport {
    struct Request: Equatable, Sendable {
        let operation: String
        let origin: URL
        let authorization: String?
    }

    private(set) var requests: [Request] = []

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        requests.append(.init(operation: operationID, origin: baseURL, authorization: request.headerFields[.authorization]))
        let status: HTTPResponse.Status = switch operationID {
        case Operations.Logout.id: .ok
        case Operations.Whoami.id: .unauthorized
        default: .notFound
        }
        return (HTTPResponse(status: status), nil)
    }
}

@MainActor
final class CredentialSessionStoreTests: XCTestCase {
    private let origin = URL(string: "https://hestia.example")!
    private let otherOrigin = URL(string: "https://hestia.example:8443")!
    private let legacyToken = "legacy-token"

    private struct Fixture {
        let defaults: InterruptedOverrideDefaults
        let keychain = TestSessionKeychain()
        let store: CredentialSessionStore

        init(legacyOrigin: URL? = nil, legacyToken: String? = nil) {
            defaults = InterruptedOverrideDefaults(suiteName: "vesta.test.session.\(UUID())")!
            if let legacyOrigin {
                defaults.set(legacyOrigin.absoluteString, forKey: BackendURLStore.userDefaultsKey)
            }
            if let legacyToken { keychain.seed(Data(legacyToken.utf8), for: .legacy) }
            store = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        }

        func restart() -> CredentialSessionStore {
            CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        }

        @discardableResult
        func seedAuthoritative(origin: URL, actor: String?, token: String) throws -> AuthoritativeSessionRecord {
            let record = AuthoritativeSessionRecord(commitID: UUID(), origin: origin, actor: actor, token: token)
            keychain.seed(try JSONEncoder().encode(record), for: .authoritative)
            return record
        }
    }

    func testSingleRecordKeychainWriteFailureHappensBeforeOverrideChangeAndKeepsPrior() throws {
        let fixture = Fixture()
        let prior = try fixture.store.commitAuthoritative(origin: origin, actor: "old", token: "old-token")
        let persisted = fixture.keychain.storedData(for: .authoritative)
        fixture.keychain.failNext(.write(.authoritative))

        XCTAssertThrowsError(try fixture.store.commitAuthoritative(origin: otherOrigin, actor: "new", token: "new-token")) {
            XCTAssertEqual($0 as? SessionKeychainError, .writeFailed)
        }
        XCTAssertEqual(fixture.keychain.storedData(for: .authoritative), persisted)
        XCTAssertEqual(fixture.restart().backendURLStore.loadOverrideRecord(), .init(urlString: origin.absoluteString, sessionCommitID: prior.commitID))
        XCTAssertEqual(fixture.store.currentSnapshot(), prior)
    }

    func testSameOriginAccountSwitchCrashReconcilesCommitIDAndIsolatesPriorUsersDeviceToken() throws {
        let fixture = Fixture()
        let prior = try fixture.store.commitAuthoritative(origin: origin, actor: "old", token: "old-token")
        let next = try fixture.seedAuthoritative(origin: origin, actor: "new", token: "new-token")
        let restarted = fixture.restart()
        let oldDevice = StoredReceiptDeviceToken(server: origin, provenance: .legacyPasswordLogin, actor: "old", credential: fakeDeviceToken)
        let deviceStore = MemoryDeviceTokenStore(oldDevice)
        let pairing = ReceiptPairing(store: deviceStore, serverURL: { restarted.backendURLStore.currentEffectiveURL() })
        pairing.bindSessionStore(restarted)

        XCTAssertEqual(restarted.backendURLStore.loadOverrideRecord()?.sessionCommitID, prior.commitID)
        XCTAssertEqual(try restarted.bootstrap(), .ready(retryCleanup: false))
        XCTAssertEqual(restarted.backendURLStore.loadOverrideRecord()?.sessionCommitID, next.commitID)
        XCTAssertEqual(restarted.currentSnapshot(), next.snapshot)
        XCTAssertNil(pairing.credential(for: origin, session: restarted.currentSnapshot()))
        XCTAssertEqual(deviceStore.load(), oldDevice)
    }

    func testChangedOriginCrashDerivesBackendURLFromAuthoritativeKeychainRecord() throws {
        let fixture = Fixture()
        try fixture.store.commitAuthoritative(origin: origin, actor: "old", token: "old-token")
        let next = try fixture.seedAuthoritative(origin: otherOrigin, actor: "new", token: "new-token")
        let restarted = fixture.restart()

        XCTAssertEqual(restarted.backendURLStore.currentEffectiveURL(), origin)
        XCTAssertEqual(try restarted.bootstrap(), .ready(retryCleanup: false))
        XCTAssertEqual(restarted.backendURLStore.currentEffectiveURL(), otherOrigin)
        XCTAssertEqual(restarted.backendURLStore.loadOverrideRecord()?.sessionCommitID, next.commitID)
        XCTAssertEqual(restarted.currentSnapshot(), next.snapshot)
    }

    func testManualSaveAndConnectKeychainLockedAbortsBeforeOverrideChange() throws {
        let fixture = Fixture()
        let prior = try fixture.store.commitAuthoritative(origin: origin, actor: "old", token: "old-token")
        let rawRecord = fixture.keychain.storedData(for: .authoritative)
        let mutations = fixture.keychain.mutations
        fixture.keychain.setLocked(true)
        let app = makeApp(sessionStore: fixture.store, transport: SessionCleanupTransport())

        XCTAssertFalse(app.saveAndConnect(otherOrigin.absoluteString))
        XCTAssertNotNil(app.sessionStorageError)
        XCTAssertEqual(fixture.restart().backendURLStore.currentEffectiveURL(), origin)
        XCTAssertEqual(fixture.keychain.storedData(for: .authoritative), rawRecord)
        XCTAssertEqual(fixture.keychain.mutations, mutations)
        XCTAssertEqual(fixture.store.currentSnapshot(), prior)
    }

    func testInterruptionAfterAuthoritativeWriteThenSignOutNeverResurrectsLegacyToken() async throws {
        let fixture = Fixture(legacyOrigin: origin, legacyToken: legacyToken)
        try fixture.seedAuthoritative(origin: origin, actor: "old", token: "verified-token")
        let restarted = fixture.restart()
        let transport = SessionCleanupTransport()
        let app = makeApp(sessionStore: restarted, transport: transport)

        let signedOut = await app.signOut()
        XCTAssertTrue(signedOut)
        let requests = await transport.requests
        XCTAssertEqual(requests, [.init(operation: Operations.Logout.id, origin: origin, authorization: "Bearer verified-token")])
        try assertSignedOut(fixture, on: origin)
    }

    func testInterruptionAfterAuthoritativeWriteThenChangedOriginSwitchNeverSendsLegacyBearer() async throws {
        let fixture = Fixture(legacyOrigin: origin, legacyToken: legacyToken)
        try fixture.seedAuthoritative(origin: origin, actor: "old", token: "verified-token")
        let restarted = fixture.restart()
        let transport = SessionCleanupTransport()
        let app = makeApp(sessionStore: restarted, transport: transport)

        XCTAssertTrue(app.saveAndConnect(otherOrigin.absoluteString))
        try await waitUntil("new origin identity request") {
            await transport.requests.contains { $0.operation == Operations.Whoami.id }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.authorization != nil }, [
            .init(operation: Operations.Logout.id, origin: origin, authorization: "Bearer verified-token"),
        ])
        XCTAssertTrue(requests.filter { $0.operation != Operations.Logout.id }.allSatisfy { $0.origin == otherOrigin })
        try assertSignedOut(fixture, on: otherOrigin)
    }

    func testMigrationWriteFaultsConvergeOnRetry() throws {
        let operations: [TestSessionKeychain.Mutation] = [
            .write(.authoritative), .write(.legacyMigrated), .delete(.legacy),
        ]
        for operation in operations {
            let fixture = Fixture(legacyOrigin: origin, legacyToken: legacyToken)
            let candidate = try legacyCandidate(from: fixture.store)
            fixture.keychain.failNext(operation)

            if operation == .write(.authoritative) {
                XCTAssertThrowsError(try fixture.store.completeLegacyMigration(candidate, actor: "old")) {
                    XCTAssertEqual($0 as? SessionKeychainError, .writeFailed)
                }
                XCTAssertNil(fixture.keychain.storedData(for: .legacyMigrated))
                XCTAssertNil(fixture.store.currentSnapshot())
                XCTAssertNil(fixture.store.backendURLStore.loadOverrideRecord()?.sessionCommitID)
            } else {
                XCTAssertTrue(try fixture.store.completeLegacyMigration(candidate, actor: "old"))
                XCTAssertEqual(fixture.store.currentSnapshot()?.token, legacyToken)
            }
            XCTAssertEqual(fixture.keychain.storedData(for: .legacy), Data(legacyToken.utf8))

            let restarted = fixture.restart()
            if operation == .write(.authoritative) {
                let retryCandidate = try legacyCandidate(from: restarted)
                XCTAssertEqual(retryCandidate, candidate)
                XCTAssertFalse(try restarted.completeLegacyMigration(retryCandidate, actor: "old"))
            } else {
                XCTAssertEqual(try restarted.bootstrap(), .ready(retryCleanup: false))
                XCTAssertEqual(restarted.currentSnapshot(), fixture.store.currentSnapshot())
            }
            assertMigrated(fixture, session: restarted.currentSnapshot())
        }
    }

    func testMigrationRecoversWhenDerivedOverrideWriteDoesNotPersist() throws {
        let fixture = Fixture(legacyOrigin: origin, legacyToken: legacyToken)
        let candidate = try legacyCandidate(from: fixture.store)
        fixture.defaults.dropNextOverrideWrite()

        XCTAssertFalse(try fixture.store.completeLegacyMigration(candidate, actor: "old"))
        let restarted = fixture.restart()
        XCTAssertNil(restarted.backendURLStore.loadOverrideRecord()?.sessionCommitID)
        XCTAssertEqual(try restarted.bootstrap(), .ready(retryCleanup: false))
        XCTAssertEqual(restarted.currentSnapshot(), fixture.store.currentSnapshot())
        assertMigrated(fixture, session: restarted.currentSnapshot())
    }

    func testMissingAuthoritativeRecordDoesNotReviveLegacyOfLinkedOverride() throws {
        let fixture = Fixture(legacyOrigin: origin, legacyToken: legacyToken)
        let linked = UUID()
        fixture.store.backendURLStore.saveOverride(origin, sessionCommitID: linked)
        fixture.keychain.failNext(.write(.legacyMigrated))

        XCTAssertThrowsError(try fixture.store.bootstrap())
        XCTAssertEqual(fixture.restart().backendURLStore.loadOverrideRecord()?.sessionCommitID, linked)
        XCTAssertEqual(try fixture.restart().bootstrap(), .signedOut(retryCleanup: false))
        try assertSignedOut(fixture, on: origin)
    }

    func testLegacyTokenWithoutOverrideIsRetiredWithoutPublication() throws {
        let fixture = Fixture(legacyToken: legacyToken)

        XCTAssertEqual(try fixture.store.bootstrap(), .ready(retryCleanup: false))
        XCTAssertFalse(fixture.store.backendURLStore.hasOverride())
        XCTAssertNil(fixture.store.currentSnapshot())
        XCTAssertNil(fixture.keychain.storedData(for: .legacy))
        XCTAssertNotNil(fixture.keychain.storedData(for: .legacyMigrated))
    }

    private func legacyCandidate(from store: CredentialSessionStore) throws -> BoundSession {
        guard case .verifyLegacy(let candidate) = try store.bootstrap() else {
            XCTFail("Expected a private legacy verification candidate")
            throw CancellationError()
        }
        XCTAssertNil(store.currentSnapshot())
        return candidate
    }

    private func assertMigrated(_ fixture: Fixture, session: BoundSession?) {
        XCTAssertEqual(session?.origin, origin)
        XCTAssertEqual(session?.actor, "old")
        XCTAssertEqual(session?.token, legacyToken)
        XCTAssertNotNil(session?.commitID)
        XCTAssertEqual(fixture.restart().backendURLStore.loadOverrideRecord()?.sessionCommitID, session?.commitID)
        XCTAssertNil(fixture.keychain.storedData(for: .legacy))
        XCTAssertNotNil(fixture.keychain.storedData(for: .legacyMigrated))
    }

    private func assertSignedOut(_ fixture: Fixture, on origin: URL) throws {
        let restarted = fixture.restart()
        XCTAssertEqual(try restarted.bootstrap(), .ready(retryCleanup: false))
        XCTAssertEqual(restarted.backendURLStore.currentEffectiveURL(), origin)
        XCTAssertNil(restarted.backendURLStore.loadOverrideRecord()?.sessionCommitID)
        XCTAssertNil(restarted.currentSnapshot())
        XCTAssertNil(fixture.keychain.storedData(for: .authoritative))
        XCTAssertNil(fixture.keychain.storedData(for: .legacy))
        XCTAssertNotNil(fixture.keychain.storedData(for: .legacyMigrated))
    }

    private func makeApp(sessionStore: CredentialSessionStore, transport: SessionCleanupTransport) -> AppState {
        AppState(api: APIClient(transport: transport, sessionStore: sessionStore),
                 receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()), sessionStore: sessionStore,
                 events: { _ in AsyncStream { $0.finish() } })
    }
}
