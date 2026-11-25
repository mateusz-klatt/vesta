import Foundation
import XCTest
@testable import Vesta

private let fakeServer = URL(string: "https://hestia.example")!
private let noEvents: @Sendable () -> AsyncStream<EventStream.Event> = { AsyncStream { $0.finish() } }
let fakeDeviceToken = ReceiptDeviceToken(token: "fake-device-token", tokenID: "fake-token-id", expiresAt: .string("fake-expiry"))

@MainActor
final class MemoryDeviceTokenStore: DeviceTokenStoring {
    private var token: StoredReceiptDeviceToken?
    private var shouldFailSave = false
    private var shouldFailClear = false
    private var shouldFailPendingSave = false
    private(set) var pending: [StoredReceiptDeviceToken] = []
    private var overflow = false
    private var journal: [RotationJournalRecord] = []
    private var rollback: [StoredReceiptDeviceToken] = []
    private var untrusted: [StoredReceiptDeviceToken] = []
    private var limits: [DeviceExchangeLimit] = []

    init(_ token: StoredReceiptDeviceToken? = nil) { self.token = token }
    func load() -> StoredReceiptDeviceToken? { token }
    func failNextSave() { shouldFailSave = true }
    func failNextClear() { shouldFailClear = true }
    func failNextPendingSave() { shouldFailPendingSave = true }
    func save(_ token: StoredReceiptDeviceToken) throws {
        if shouldFailSave {
            shouldFailSave = false
            throw DevicePairingError.storage
        }
        self.token = token
    }
    func clear() throws {
        if shouldFailClear {
            shouldFailClear = false
            throw DevicePairingError.storage
        }
        token = nil
    }
    func loadPendingRevocations() -> [StoredReceiptDeviceToken] { pending }
    func savePendingRevocations(_ tokens: [StoredReceiptDeviceToken]) throws {
        if shouldFailPendingSave {
            shouldFailPendingSave = false
            throw DevicePairingError.storage
        }
        pending = tokens
    }
    func hasPendingRevocationOverflow() -> Bool { overflow }
    func markPendingRevocationOverflow() { overflow = true }
    func loadRotationJournal() -> [RotationJournalRecord] { journal }
    func saveRotationJournal(_ records: [RotationJournalRecord]) { journal = records }
    func loadRollbackQuarantine() -> [StoredReceiptDeviceToken] { rollback }
    func saveRollbackQuarantine(_ tokens: [StoredReceiptDeviceToken]) { rollback = tokens }
    func loadUntrustedExchangeTokens() -> [StoredReceiptDeviceToken] { untrusted }
    func saveUntrustedExchangeTokens(_ tokens: [StoredReceiptDeviceToken]) { untrusted = tokens }
    func loadDeviceExchangeLimits() -> [DeviceExchangeLimit] { limits }
    func saveDeviceExchangeLimits(_ limits: [DeviceExchangeLimit]) { self.limits = limits }
}

private actor MockDevicePairingAPI: DevicePairingAPI {
    enum Call: Equatable {
        case redeem(ReceiptPairingCode, String, URL)
        case login(String, String, String, URL)
        case revoke(ReceiptDeviceToken, URL)
        case exchange(BoundSession, String, ReceiptDeviceToken?)
    }
    enum RevokeBehavior: Sendable {
        case success, offline, expired, revoked, notFound, disabled, unauthorized, invalid, unavailable
    }

    private(set) var calls: [Call] = []
    private var revokeBehavior: RevokeBehavior
    private var holdRedeem: Bool
    private var loginError: DevicePairingError?
    private var redeemGate: CheckedContinuation<Void, Never>?
    private var exchangeResults: [Result<ExchangedDeviceToken, any Error>] = []
    private var holdExchange = false
    private var exchangeGate: CheckedContinuation<Void, Never>?

    init(failRevoke: Bool = false, holdRedeem: Bool = false) {
        revokeBehavior = failRevoke ? .offline : .success
        self.holdRedeem = holdRedeem
    }

    func setRevokeBehavior(_ behavior: RevokeBehavior) {
        revokeBehavior = behavior
    }

    func failLogin(with error: DevicePairingError) {
        loginError = error
    }

    func login(username: String, password: String, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        calls.append(.login(username, password, deviceName, server))
        if holdRedeem {
            await withCheckedContinuation { redeemGate = $0 }
        }
        if let loginError { throw loginError }
        return fakeDeviceToken
    }

    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        calls.append(.redeem(code, deviceName, server))
        if holdRedeem {
            await withCheckedContinuation { redeemGate = $0 }
        }
        return fakeDeviceToken
    }

    func releaseRedeem() {
        holdRedeem = false
        redeemGate?.resume()
        redeemGate = nil
    }

    func setExchangeResults(_ results: [Result<ExchangedDeviceToken, any Error>], holdFirst: Bool = false) {
        exchangeResults = results
        holdExchange = holdFirst
    }

    var isExchangeHeld: Bool { exchangeGate != nil }

    func releaseExchange() {
        exchangeGate?.resume()
        exchangeGate = nil
    }

    func exchange(session: BoundSession, deviceName: String, priorToken: ReceiptDeviceToken?) async throws -> ExchangedDeviceToken {
        calls.append(.exchange(session, deviceName, priorToken))
        let result = exchangeResults.isEmpty ? .failure(DeviceExchangeError.http(status: 501, code: nil)) : exchangeResults.removeFirst()
        if holdExchange {
            holdExchange = false
            await withCheckedContinuation { exchangeGate = $0 }
        }
        return try result.get()
    }

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        calls.append(.revoke(token, server))
        switch revokeBehavior {
        case .success: break
        case .offline: throw URLError(.notConnectedToInternet)
        case .expired: throw DeviceRevocationError.http(status: 401, code: "device_token_expired")
        case .revoked: throw DeviceRevocationError.http(status: 401, code: "device_token_revoked")
        case .notFound: throw DeviceRevocationError.http(status: 404, code: nil)
        case .disabled: throw DeviceRevocationError.http(status: 404, code: "budget_receipts_disabled")
        case .unauthorized: throw DeviceRevocationError.http(status: 401, code: nil)
        case .invalid: throw DeviceRevocationError.http(status: 401, code: "device_token_invalid")
        case .unavailable: throw DeviceRevocationError.http(status: 503, code: nil)
        }
    }
}

private final class DevicePairingURLProtocol: URLProtocol, @unchecked Sendable {
    static let rateLimitedCode = "23456789"
    static let rejectedPassword = "fake-wrong-password"
    static let limitPassword = "fake-limit-password"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, fakeServer.host)
            XCTAssertEqual(request.httpMethod, "POST")
            let contentType = request.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first
            XCTAssertEqual(contentType, "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

            let body: Any
            if let data = request.httpBody {
                body = try JSONSerialization.jsonObject(with: data)
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                body = try JSONSerialization.jsonObject(with: stream)
            }
            let json = try XCTUnwrap(body as? [String: String])
            let responseBody: String
            let status: Int
            var headers = ["Content-Type": "application/json"]
            switch url.path {
            case "/api/budget/receipts/device-token/redeem":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                if json["code"] == Self.rateLimitedCode {
                    responseBody = #"{"ok":false,"error":"device_token_rejected"}"#
                    status = 429
                    headers["Retry-After"] = "60"
                } else {
                    XCTAssertEqual(json, ["code": "ABCD2345", "device_name": "iPhone"])
                    responseBody = #"{"token":"fake-device-token","token_id":"fake-token-id","scope":"receipts","expires_at":"2027-02-21T18:00:00.125+00:00"}"#
                    status = 200
                }
            case "/api/budget/receipts/device-token/login":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                if json["password"] == Self.rejectedPassword {
                    responseBody = #"{"ok":false,"error":"device_token_rejected"}"#
                    status = 401
                } else if json["password"] == Self.limitPassword {
                    responseBody = #"{"ok":false,"error":"device_token_limit_reached"}"#
                    status = 409
                } else {
                    XCTAssertEqual(json, ["username": "owner", "password": "fake-password", "device_name": "iPhone 1A2B"])
                    responseBody = #"{"token":"fake-device-token","token_id":"fake-token-id","scope":"receipts","expires_at":"2027-02-21T18:00:00.125+00:00"}"#
                    status = 200
                }
            case "/api/budget/receipts/device-token/revoke":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-device-token")
                XCTAssertEqual(json, ["token_id": "fake-token-id"])
                responseBody = #"{"ok":true}"#
                status = 200
            default:
                XCTFail("Unexpected pairing endpoint")
                responseBody = ""
                status = 404
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                       headerFields: headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class DevicePairingTests: XCTestCase {
    @MainActor
    private struct CodeSessionFixture {
        let defaults: UserDefaults
        let keychain = TestSessionKeychain()
        let session: CredentialSessionStore
        let oldSession: BoundSession
        let oldDevice: StoredReceiptDeviceToken
        let devices: MemoryDeviceTokenStore
        let pairingAPI = MockDevicePairingAPI()
        let homeAPI = MockHestiaAPI()

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: "device-reset-\(UUID())"))
            session = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
            oldSession = try session.commitAuthoritative(origin: fakeServer, actor: "owner", token: "old-session")
            oldDevice = StoredReceiptDeviceToken(server: fakeServer, provenance: .legacyCodeRedeem,
                                                 sessionCommitID: oldSession.commitID, credential: fakeDeviceToken)
            devices = MemoryDeviceTokenStore(oldDevice)
        }

        func makeApp(session: CredentialSessionStore) -> AppState {
            let pairing = ReceiptPairing(api: pairingAPI, store: devices,
                                         serverURL: { session.backendURLStore.currentEffectiveURL() })
            return AppState(api: homeAPI, receiptPairing: pairing, sessionStore: session, events: noEvents)
        }

        func makeRestartedSession() -> CredentialSessionStore {
            CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
        }
    }

    func testSameOriginResetAndRelaunchRebindsCodeCredentialOnlyForSameActor() async throws {
        for actor in ["owner", "other"] {
            let fixture = try CodeSessionFixture()
            let app = fixture.makeApp(session: fixture.session)
            await fixture.homeAPI.setCapabilitiesError(.unauthorized)

            XCTAssertTrue(app.saveAndConnect("https://hestia.example:443"))
            try await waitUntil("same-origin reset to reach sign-in") { app.phase == .needsAuth }
            XCTAssertNil(fixture.session.currentSnapshot())
            XCTAssertEqual(fixture.devices.load()?.sessionCommitID, fixture.oldSession.commitID)
            XCTAssertNil(app.receiptPairing.credential(for: fakeServer))

            let restarted = fixture.makeRestartedSession()
            let relaunched = fixture.makeApp(session: restarted)
            await relaunched.bootstrap()
            XCTAssertEqual(relaunched.phase, .needsAuth)
            await fixture.homeAPI.setCapabilities(Capabilities(user: actor))
            await relaunched.login(user: actor, password: "fake-password")

            let replacement = try XCTUnwrap(restarted.currentSnapshot())
            XCTAssertNotEqual(replacement.commitID, fixture.oldSession.commitID)
            XCTAssertEqual(replacement.actor, actor)
            XCTAssertEqual(relaunched.phase, .ready)
            let calls = await fixture.pairingAPI.calls
            if actor == "owner" {
                let retained = try XCTUnwrap(relaunched.receiptPairing.credential(for: replacement.origin))
                XCTAssertEqual(retained.credential, fakeDeviceToken)
                XCTAssertEqual(retained.sessionCommitID, replacement.commitID)
                XCTAssertNil(retained.actor)
                XCTAssertNil(retained.owner)
                XCTAssertTrue(calls.isEmpty)
            } else {
                XCTAssertNil(fixture.devices.load())
                XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer)])
            }
            XCTAssertTrue(fixture.devices.pending.isEmpty)
        }
    }

    func testCodeHandoffWriteFailureAbortsResetAndRebindWriteFailureAbortsLogin() async throws {
        let fixture = try CodeSessionFixture()
        let app = fixture.makeApp(session: fixture.session)
        await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
        await app.bootstrap()

        fixture.devices.failNextSave()
        XCTAssertFalse(app.saveAndConnect(fakeServer.absoluteString))
        XCTAssertEqual(app.sessionStorageError, .credentialStorage)
        XCTAssertEqual(fixture.session.currentSnapshot(), fixture.oldSession)
        XCTAssertEqual(app.receiptPairing.credential(for: fakeServer), fixture.oldDevice)

        await fixture.homeAPI.setCapabilitiesError(.unauthorized)
        XCTAssertTrue(app.saveAndConnect(fakeServer.absoluteString))
        try await waitUntil("sign-in after retrying the same-origin reset") { app.phase == .needsAuth }
        await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
        fixture.devices.failNextSave()
        await app.login(user: "owner", password: "fake-password")
        XCTAssertEqual(app.sessionStorageError, .credentialStorage)
        XCTAssertNil(fixture.session.currentSnapshot())
        XCTAssertNil(fixture.keychain.storedData(for: .authoritative))
        XCTAssertEqual(fixture.devices.load()?.sessionCommitID, fixture.oldSession.commitID)

        await app.login(user: "owner", password: "fake-password")
        let replacement = try XCTUnwrap(fixture.session.currentSnapshot())
        XCTAssertEqual(app.receiptPairing.credential(for: fakeServer)?.sessionCommitID, replacement.commitID)
        XCTAssertEqual(app.phase, .ready)
    }

    func testFailedAuthoritativeWriteKeepsPreviousCodeBindingUntilRetry() async throws {
        let fixture = try CodeSessionFixture()
        let app = fixture.makeApp(session: fixture.session)
        await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
        await app.bootstrap()
        fixture.keychain.failNext(.write(.authoritative))

        await app.login(user: "owner", password: "fake-password")

        XCTAssertEqual(fixture.session.currentSnapshot(), fixture.oldSession)
        XCTAssertEqual(app.receiptPairing.credential(for: fakeServer)?.credential, fakeDeviceToken)
        XCTAssertNotNil(app.sessionStorageError)
        await app.login(user: "owner", password: "fake-password")
        let replacement = try XCTUnwrap(fixture.session.currentSnapshot())
        XCTAssertNotEqual(replacement.commitID, fixture.oldSession.commitID)
        XCTAssertEqual(app.receiptPairing.credential(for: fakeServer)?.sessionCommitID, replacement.commitID)
    }

    func testSignOutAndSwitchAbortWhenDetachCannotBeStaged() async throws {
        let newOrigin = URL(string: "https://hestia.example:8443")!
        for switchServer in [false, true] {
            let fixture = try CodeSessionFixture()
            let app = fixture.makeApp(session: fixture.session)
            await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
            await app.bootstrap()
            fixture.devices.failNextPendingSave()

            let changed: Bool
            if switchServer { changed = app.saveAndConnect(newOrigin.absoluteString) }
            else { changed = await app.signOut() }

            XCTAssertFalse(changed)
            XCTAssertEqual(app.phase, .ready)
            XCTAssertEqual(app.sessionStorageError, .credentialStorage)
            XCTAssertEqual(fixture.session.currentSnapshot(), fixture.oldSession)
            XCTAssertEqual(fixture.session.backendURLStore.currentEffectiveURL(), fakeServer)
            XCTAssertEqual(app.receiptPairing.credential(for: fakeServer), fixture.oldDevice)
            XCTAssertTrue(fixture.devices.pending.isEmpty)
            let calls = await fixture.pairingAPI.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }

    func testSignOutClearFailureLeavesDurableDetachForForegroundRetry() async throws {
        let fixture = try CodeSessionFixture()
        let app = fixture.makeApp(session: fixture.session)
        await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
        await app.bootstrap()
        fixture.devices.failNextClear()

        let signedOut = await app.signOut()

        XCTAssertTrue(signedOut)
        XCTAssertEqual(app.phase, .needsAuth)
        XCTAssertEqual(app.receiptPairing.revocationNotice?.key, DevicePairingError.storage.message.key)
        XCTAssertNil(fixture.session.currentSnapshot())
        XCTAssertEqual(fixture.devices.load(), fixture.oldDevice)
        XCTAssertEqual(fixture.devices.pending, [fixture.oldDevice])
        XCTAssertNil(app.receiptPairing.credential(for: fakeServer))

        app.enterForeground()
        try await waitUntil("the interrupted detach to clear its pending copy") { fixture.devices.pending.isEmpty }
        XCTAssertNil(fixture.devices.load())
        XCTAssertNil(app.receiptPairing.revocationNotice)
        let calls = await fixture.pairingAPI.calls
        XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer)])
    }

    func testBootstrapFinishesInterruptedDetachOnlyAfterOldBindingIsGone() async throws {
        for hasAuthority in [true, false] {
            let fixture = try CodeSessionFixture()
            try fixture.devices.savePendingRevocations([fixture.oldDevice])
            if hasAuthority {
                await fixture.homeAPI.setCapabilities(Capabilities(user: "owner"))
            } else {
                try fixture.session.clearAuthoritative()
                await fixture.homeAPI.setCapabilitiesError(.unauthorized)
            }
            let restarted = fixture.makeRestartedSession()
            let app = fixture.makeApp(session: restarted)

            await app.bootstrap()

            if hasAuthority {
                XCTAssertEqual(app.receiptPairing.credential(for: fakeServer), fixture.oldDevice)
                XCTAssertEqual(fixture.devices.pending, [fixture.oldDevice])
                let calls = await fixture.pairingAPI.calls
                XCTAssertTrue(calls.isEmpty)
            } else {
                try await waitUntil("the relaunched app to finish detaching") { fixture.devices.pending.isEmpty }
                XCTAssertNil(fixture.devices.load())
                XCTAssertNil(app.receiptPairing.revocationNotice)
                let calls = await fixture.pairingAPI.calls
                XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer)])
            }
        }
    }

    func testTypedCodeIsCrockfordBase32AndNormalizesLikeHestia() {
        for input in ["ABCD2345", "abcd2345", " ab cd-23 45 "] {
            XCTAssertEqual(ReceiptPairingCode(input)?.value, "ABCD2345")
        }
        XCTAssertEqual(ReceiptPairingCode("0189XYZ7")?.value, "0189XYZ7")
        XCTAssertEqual(ReceiptPairingCode("oIlL-89AB")?.value, "011189AB")   // O→0, I/L→1
        for input in ["ABCD234", "ABCD23456", "ABCU2345", "ABCİ2345", "ABCD234ß", "ABCD2345!", ""] {
            XCTAssertNil(ReceiptPairingCode(input))
        }
    }

    func testQRRequiresExactPrefixAndNormalizesOnlyTheCode() {
        XCTAssertEqual(ReceiptPairingCode(qrPayload: "hestia-pair:ABCD2345")?.value, "ABCD2345")
        XCTAssertEqual(ReceiptPairingCode(qrPayload: "hestia-pair:ab cd-23 45")?.value, "ABCD2345")
        for input in ["ABCD2345", "other:ABCD2345", "HESTIA-pair:ABCD2345",
                      " hestia-pair:ABCD2345", "hestia-pair://ABCD2345",
                      "hestia-pair:ABCD234", "hestia-pair:ABCD23450", "hestia-pair:ABCDU123"] {
            XCTAssertNil(ReceiptPairingCode(qrPayload: input))
        }
    }

    func testGeneratedRedeemAndRevokeWireRequests() async throws {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [DevicePairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = GeneratedDevicePairingAPI(session: session)
        let code = try XCTUnwrap(ReceiptPairingCode("abcd-2345"))
        let token = try await api.redeem(code: code, deviceName: "iPhone", server: fakeServer)
        XCTAssertEqual(token.token, fakeDeviceToken.token)
        XCTAssertEqual(token.tokenID, fakeDeviceToken.tokenID)
        XCTAssertEqual(token.expiresAt, .string("2027-02-21T18:00:00.125Z"))
        try await api.revoke(token, server: fakeServer)
    }

    func testGeneratedLoginSendsCredentialsWithoutCookieOrAuthorization() async throws {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [DevicePairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = GeneratedDevicePairingAPI(session: session)
        let token = try await api.login(username: "owner", password: "fake-password",
                                        deviceName: "iPhone 1A2B", server: fakeServer)
        XCTAssertEqual(token.token, fakeDeviceToken.token)
        XCTAssertEqual(token.tokenID, fakeDeviceToken.tokenID)
        do {
            _ = try await api.login(username: "owner", password: DevicePairingURLProtocol.rejectedPassword,
                                    deviceName: "iPhone 1A2B", server: fakeServer)
            XCTFail("Expected rejected credentials")
        } catch let error as DevicePairingError {
            guard case .redeemFailed = error else { return XCTFail("Expected a generic pairing failure") }
        }
    }

    func testAdminLoginPairsReceiptsWithTheSameCredentials() async throws {
        let api = MockDevicePairingAPI()
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setWhoami(role: "admin")
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

        await app.login(user: "owner", password: "fake-password")

        let calls = await api.calls
        XCTAssertEqual(calls, [.login("owner", "fake-password", ReceiptPairing.deviceName, fakeServer)])
        XCTAssertEqual(pairing.status, .paired)
        XCTAssertEqual(store.load()?.credential, fakeDeviceToken)
        XCTAssertEqual(store.load()?.provenance, .legacyPasswordLogin)
        XCTAssertEqual(store.load()?.actor, "owner")
    }

    func testLoginSkipsAutoPairingForNonAdminsAndPairedDevices() async throws {
        for (role, stored) in [("operator", nil), ("viewer", nil),
                               ("admin", StoredReceiptDeviceToken(server: fakeServer, provenance: .legacyPasswordLogin,
                                                                 actor: "owner", credential: fakeDeviceToken))] {
            let api = MockDevicePairingAPI()
            let pairing = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(stored), serverURL: { fakeServer })
            let hestia = MockHestiaAPI()
            await hestia.setWhoami(role: role)
            let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

            await app.login(user: "owner", password: "fake-password")

            let calls = await api.calls
            XCTAssertEqual(calls, [], role)
            XCTAssertEqual(pairing.credential(for: fakeServer), stored)
        }
    }

    func testFreshPasswordLoginCannotClaimAnUnverifiedLegacyReceiptCredential() async throws {
        let api = MockDevicePairingAPI()
        let legacy = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let store = MemoryDeviceTokenStore(legacy)
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setWhoami(role: "admin")
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

        await app.login(user: "owner", password: "fake-password")

        XCTAssertNil(pairing.credential(for: fakeServer))
        XCTAssertEqual(store.load(), legacy)
        XCTAssertEqual(pairing.status, .notPaired)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testFailedAutoPairingLeavesTheCodeFlow() async throws {
        for error in [DevicePairingError.redeemFailed, .rateLimited, .receipts(.disabled)] {
            let api = MockDevicePairingAPI()
            await api.failLogin(with: error)
            let store = MemoryDeviceTokenStore()
            let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
            let hestia = MockHestiaAPI()
            await hestia.setWhoami(role: "admin")
            let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

            await app.login(user: "owner", password: "fake-password")

            XCTAssertEqual(pairing.status, .notPaired)
            XCTAssertNil(store.load())
            let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
            try await pairing.pair(code: code, deviceName: "iPhone")
            XCTAssertEqual(pairing.status, .paired)
        }
    }

    func testAutoPairingOnlyUsesHTTPSAndTheLoginServer() async throws {
        let api = MockDevicePairingAPI()
        let pairing = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(), serverURL: { fakeServer })
        try await pairing.pair(username: "owner", password: "fake-password", deviceName: "iPhone",
                               server: URL(string: "https://other.example")!)
        let http = URL(string: "http://192.168.1.10:8080")!
        let lan = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(), serverURL: { http })
        try await lan.pair(username: "owner", password: "fake-password", deviceName: "iPhone", server: http)
        let calls = await api.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertEqual(lan.status, .notPaired)
    }

    func testSignOutDuringLoginStopsAutoPairing() async throws {
        let api = MockDevicePairingAPI()
        let pairing = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(), serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setWhoami(role: "admin")
        await hestia.setHoldLogin()
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

        let login = Task { await app.login(user: "owner", password: "fake-password") }
        while await hestia.calls.isEmpty { await Task.yield() }
        await app.signOut()
        await hestia.releaseLogin()
        await login.value

        let calls = await api.calls
        XCTAssertEqual(calls, [])
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertEqual(app.phase, .needsAuth)
    }

    func testDeviceLimitOnLoginIsReportedAndClearedByCodePairing() async throws {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [DevicePairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await GeneratedDevicePairingAPI(session: session).login(
                username: "owner", password: DevicePairingURLProtocol.limitPassword,
                deviceName: "iPhone 1A2B", server: fakeServer)
            XCTFail("Expected the device limit")
        } catch let error as DevicePairingError {
            guard case .deviceLimit = error else { return XCTFail("Expected the device limit") }
        }
        XCTAssertEqual(ReceiptError.from(status: 409, code: "device_token_limit_reached"), .deviceLimit)

        let api = MockDevicePairingAPI()
        await api.failLogin(with: .deviceLimit)
        let pairing = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(), serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setWhoami(role: "admin")
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)

        await app.login(user: "owner", password: "fake-password")

        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertEqual(pairing.pairingNotice?.key,
                       "hestia already has 5 paired devices. Remove one in hestia’s device list, or pair with a code.")
        let loginCalls = await api.calls
        XCTAssertEqual(loginCalls.count, 1, "no retry at the limit")

        try await pairing.pair(code: try XCTUnwrap(ReceiptPairingCode("ABCD2345")), deviceName: "iPhone")
        XCTAssertEqual(pairing.status, .paired)
        XCTAssertNil(pairing.pairingNotice)
    }

    func testLateDeviceLimitAfterUnpairLeavesNoNotice() async throws {
        let api = MockDevicePairingAPI(holdRedeem: true)
        await api.failLogin(with: .deviceLimit)
        let pairing = ReceiptPairing(api: api, store: MemoryDeviceTokenStore(), serverURL: { fakeServer })
        let login = Task {
            try await pairing.pair(username: "owner", password: "fake-password", deviceName: "iPhone", server: fakeServer)
        }
        while await api.calls.isEmpty { await Task.yield() }
        try await pairing.unpair()
        await api.releaseRedeem()
        _ = try? await login.value
        XCTAssertNil(pairing.pairingNotice)
        XCTAssertEqual(pairing.status, .notPaired)
    }

    func testDeviceNameIsStableAndFitsHestiasLimit() {
        let name = ReceiptPairing.deviceName
        XCTAssertEqual(name, ReceiptPairing.deviceName)
        XCTAssertFalse(name.isEmpty)
        XCTAssertLessThanOrEqual(name.count, 64)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.controlCharacters.contains($0) })
    }

    func testRateLimitedRedeemAsksTheUserToWait() async throws {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [DevicePairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let pairing = ReceiptPairing(api: GeneratedDevicePairingAPI(session: session),
                                     store: MemoryDeviceTokenStore(), serverURL: { fakeServer })
        let code = try XCTUnwrap(ReceiptPairingCode(DevicePairingURLProtocol.rateLimitedCode))

        do {
            try await pairing.pair(code: code, deviceName: "iPhone")
            XCTFail("Expected the redeem request to be rate limited")
        } catch let error as DevicePairingError {
            guard case .rateLimited = error else {
                return XCTFail("Expected a pairing rate limit")
            }
            XCTAssertEqual(error.message.key, "Too many pairing attempts. Try again in a minute.")
        }
        XCTAssertEqual(pairing.status, .notPaired)
    }

    func testKeychainRoundTripReplacesAndRemovesCredential() throws {
        let store: any DeviceTokenStoring = KeychainDeviceTokenStore(account: "test-\(UUID())")
        defer {
            try? store.clear()
            try? store.savePendingRevocations([])
        }
        XCTAssertNil(try store.load())

        let original = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        try store.save(original)
        XCTAssertEqual(try store.load(), original)

        let replacement = StoredReceiptDeviceToken(server: fakeServer, credential:
            .init(token: "fake-replacement", tokenID: "fake-replacement-id", expiresAt: .number(123.5)))
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
    }

    func testMissingProvenanceDecodesAsLegacyMigrated1xOnActiveAndPendingRecords() throws {
        struct LegacyRecord: Encodable {
            let server: URL
            let credential: ReceiptDeviceToken
        }
        let active = LegacyRecord(server: fakeServer, credential: fakeDeviceToken)
        let olderOrigin = try XCTUnwrap(URL(string: "https://hestia.example:8443"))
        let pending = LegacyRecord(server: olderOrigin, credential: .init(
            token: "pending-token", tokenID: "pending-id", expiresAt: .number(1_700_000_000)
        ))
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let loaded = try decoder.decode(StoredReceiptDeviceToken.self, from: encoder.encode(active))
        let revocations = try decoder.decode([StoredReceiptDeviceToken].self, from: encoder.encode([pending]))

        XCTAssertEqual(loaded, .init(server: fakeServer, credential: active.credential))
        XCTAssertEqual(revocations, [.init(server: olderOrigin, credential: pending.credential)])
        for record in [loaded] + revocations {
            XCTAssertEqual(record.provenance, .legacyMigrated1x)
            XCTAssertNil(record.actor)
            XCTAssertNil(record.owner)
            XCTAssertNil(record.ownerKey)
            XCTAssertNil(record.sessionCommitID)
        }
    }

    func testLegacyReceiptScopeWriteFailureKeepsCredentialAndPendingRevocationsForRetry() throws {
        let legacy = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let pending = StoredReceiptDeviceToken(server: try XCTUnwrap(URL(string: "https://hestia.example:8443")),
            credential: .init(token: "pending-token", tokenID: "pending-id", expiresAt: .number(1_700_000_000)))
        let store = MemoryDeviceTokenStore(legacy)
        try store.savePendingRevocations([pending])
        let pairing = ReceiptPairing(store: store, serverURL: { fakeServer })
        store.failNextSave()

        XCTAssertThrowsError(try pairing.bindLegacyCredential(origin: fakeServer, actor: "owner"))
        XCTAssertEqual(store.load(), legacy)
        XCTAssertEqual(store.pending, [pending])

        try pairing.bindLegacyCredential(origin: fakeServer, actor: "owner")
        XCTAssertEqual(store.load(), legacy.withScope(actor: "owner"))
        XCTAssertEqual(store.pending, [pending])
    }

    func testPairPersistsAndRestoresCredentialOnlyForItsServer() async throws {
        let api = MockDevicePairingAPI()
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let code = try XCTUnwrap(ReceiptPairingCode("abcd-2345"))
        XCTAssertEqual(pairing.status, .notPaired)

        try await pairing.pair(code: code, deviceName: "iPhone")
        let calls = await api.calls
        XCTAssertEqual(calls, [.redeem(code, "iPhone", fakeServer)])
        XCTAssertEqual(pairing.status, .paired)
        XCTAssertEqual(store.load()?.provenance, .legacyCodeRedeem)
        XCTAssertNil(store.load()?.actor)
        XCTAssertNil(store.load()?.owner)
        let restored = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        XCTAssertEqual(restored.status, .paired)
        XCTAssertEqual(restored.credential(for: fakeServer)?.credential, fakeDeviceToken)

        let otherServer = URL(string: "https://other.example")!
        let other = ReceiptPairing(api: api, store: store, serverURL: { otherServer })
        XCTAssertEqual(other.status, .notPaired)
        XCTAssertNil(other.credential(for: otherServer))
        XCTAssertNil(other.credential(for: fakeServer))
    }

    func testCodeRedeemKeepsUnverifiedIdentityAcrossRelaunchAndRejectsSameOriginAccountSwitch() async throws {
        let suite = "device-pairing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = BackendURLStore(userDefaults: defaults)
        let keychain = TestSessionKeychain()
        let session = CredentialSessionStore(backendURLStore: backend, keychain: keychain)
        let old = try session.commitAuthoritative(origin: fakeServer, actor: "first", token: "old-session")
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: MockDevicePairingAPI(), store: store, serverURL: { fakeServer })
        pairing.bindSessionStore(session)
        try await pairing.pair(code: try XCTUnwrap(ReceiptPairingCode("ABCD2345")), deviceName: "iPhone")

        let original = try XCTUnwrap(store.load())
        XCTAssertEqual(original.provenance, .legacyCodeRedeem)
        XCTAssertEqual(original.sessionCommitID, old.commitID)
        XCTAssertNil(original.actor)
        XCTAssertNil(original.owner)

        let restartedStore = CredentialSessionStore(backendURLStore: backend, keychain: keychain)
        _ = try restartedStore.bootstrap()
        let roundTrip = try JSONDecoder().decode(StoredReceiptDeviceToken.self, from: JSONEncoder().encode(original))
        let restoredDeviceStore = MemoryDeviceTokenStore(roundTrip)
        let restored = ReceiptPairing(store: restoredDeviceStore, serverURL: { fakeServer })
        restored.bindSessionStore(restartedStore)
        XCTAssertEqual(restored.credential(for: fakeServer), original)

        let renewed = try restartedStore.commitAuthoritative(origin: fakeServer, actor: "first", token: "renewed-session") {
            XCTAssertNil(try restored.prepareForLogin(from: old, to: $0))
        }
        XCTAssertEqual(restored.credential(for: fakeServer)?.sessionCommitID, renewed.commitID)
        XCTAssertNil(restored.credential(for: fakeServer)?.actor)

        let switched = try restartedStore.commitAuthoritative(origin: fakeServer, actor: "second", token: "new-session") {
            let staged = try restored.prepareForLogin(from: renewed, to: $0)
            XCTAssertEqual(staged?.credential, original.credential)
        }
        XCTAssertNil(restored.credential(for: fakeServer, session: switched))
        XCTAssertNil(restored.credential(for: fakeServer, session: renewed))
        XCTAssertEqual(restoredDeviceStore.load()?.credential, original.credential)
    }

    func testUnpairRevokesAndClearsEvenWhenRevokeFails() async throws {
        for failRevoke in [false, true] {
            let api = MockDevicePairingAPI(failRevoke: failRevoke)
            let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
            let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })

            try await pairing.unpair()
            let calls = await api.calls
            XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer)])
            XCTAssertNil(store.load())
            XCTAssertEqual(store.pending.count, failRevoke ? 1 : 0)
            XCTAssertEqual(pairing.status, .notPaired)
        }
    }

    func testUnpairLeavesNoticeWhenServerRevokeFails() async throws {
        let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(api: MockDevicePairingAPI(failRevoke: true),
                                     store: store, serverURL: { fakeServer })
        XCTAssertNil(pairing.revocationNotice)

        try await pairing.unpair()

        XCTAssertNil(store.load())
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertNil(pairing.credential(for: fakeServer))
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertEqual(pairing.revocationNotice?.key, "Couldn't reach hestia. Remove this iPhone in hestia's device list.")
    }

    func testSignOutRevokesAndClearsEvenWhenOffline() async throws {
        let api = MockDevicePairingAPI(failRevoke: true)
        let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        let suite = "device-pairing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults),
                                             keychain: TestSessionKeychain())
        try session.commitAuthoritative(origin: fakeServer, actor: "owner", token: "old-session")
        let app = AppState(api: hestia, receiptPairing: pairing, sessionStore: session, events: noEvents)

        await app.signOut()
        let calls = await api.calls
        let homeCalls = await hestia.calls
        XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer)])
        XCTAssertEqual(homeCalls, [.logout])
        XCTAssertNil(store.load())
        XCTAssertEqual(store.pending.count, 1)
        XCTAssertEqual(app.phase, .needsAuth)
        XCTAssertNotNil(app.receiptPairing.revocationNotice)
    }

    func testSignOutRevokesLateRedeemWithoutRestoringPairing() async throws {
        let api = MockDevicePairingAPI(holdRedeem: true)
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setAuthOff()
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)
        await app.connect()
        let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
        let redeem = Task { try await pairing.pair(code: code, deviceName: "iPhone") }
        while await api.calls.isEmpty { await Task.yield() }

        await app.signOut()
        await api.releaseRedeem()
        do {
            try await redeem.value
            XCTFail("Expected the pairing to be canceled")
        } catch is CancellationError {}

        let calls = await api.calls
        XCTAssertEqual(calls, [.redeem(code, "iPhone", fakeServer), .revoke(fakeDeviceToken, fakeServer)])
        XCTAssertNil(store.load())
        XCTAssertEqual(pairing.status, .notPaired)
    }

    func testKeychainPendingRevocationIsSeparateFromCredential() throws {
        let store = KeychainDeviceTokenStore(account: "test-\(UUID())")
        defer {
            try? store.clear()
            try? store.savePendingRevocations([])
        }
        let active = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let pending = StoredReceiptDeviceToken(
            server: URL(string: "https://old.example")!,
            credential: .init(token: "old-token", tokenID: "old-id", expiresAt: .string("old-expiry"))
        )
        try store.save(active)
        try store.addPendingRevocation(pending)

        XCTAssertEqual(try store.load(), active)
        XCTAssertEqual(try store.loadPendingRevocations(), [pending])
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertEqual(try store.loadPendingRevocations(), [pending])
        try store.removePendingRevocation(pending)
        XCTAssertTrue(try store.loadPendingRevocations().isEmpty)
    }

    func testDetachingKeepsTheFullPendingQueueUntilTheDetachedCredentialIsRevoked() async throws {
        let active = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let pending = (0..<5).map { index in
            StoredReceiptDeviceToken(server: fakeServer, credential: .init(
                token: "pending-token-\(index)", tokenID: "pending-id-\(index)", expiresAt: .string("expiry")
            ))
        }
        let store = MemoryDeviceTokenStore(active)
        try store.savePendingRevocations(pending)
        let pairing = ReceiptPairing(api: MockDevicePairingAPI(), store: store, serverURL: { fakeServer })

        let detached = try XCTUnwrap(pairing.detachActive(try pairing.currentActiveToken()))
        XCTAssertNil(store.load())
        XCTAssertEqual(store.pending, pending + [active])

        try await pairing.revokeDetached(detached)
        XCTAssertEqual(store.pending, pending)
    }

    func testManagedPairingRequiresAPublishedSessionAndKeepsStableDeviceIDOnReplacement() async throws {
        let suite = "device-pairing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults),
                                             keychain: TestSessionKeychain())
        let old = StoredReceiptDeviceToken(server: fakeServer, provenance: .legacyPasswordLogin, actor: "first",
            credential: .init(token: "retired-device-token", tokenID: fakeDeviceToken.tokenID, expiresAt: .string("expiry")))
        let api = MockDevicePairingAPI()
        let store = MemoryDeviceTokenStore(old)
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        pairing.bindSessionStore(session)
        let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))

        try await pairing.pair(code: code, deviceName: "iPhone")
        let signedOutCalls = await api.calls
        XCTAssertTrue(signedOutCalls.isEmpty)
        XCTAssertEqual(store.load(), old)

        try session.commitAuthoritative(origin: fakeServer, actor: "second", token: "session-token")
        try await pairing.pair(code: code, deviceName: "iPhone")
        let calls = await api.calls
        XCTAssertEqual(calls, [.redeem(code, "iPhone", fakeServer)])
        XCTAssertEqual(pairing.credential(for: fakeServer)?.credential, fakeDeviceToken)
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testRefreshRetriesAndClearsPendingRevocationOnTerminalResults() async throws {
        let behaviors: [(MockDevicePairingAPI.RevokeBehavior, String)] = [
            (.success, "success"),
            (.expired, "expired"),
            (.revoked, "revoked"),
        ]
        for (behavior, name) in behaviors {
            let api = MockDevicePairingAPI(failRevoke: true)
            let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
            let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
            try await pairing.unpair()
            XCTAssertEqual(store.pending.count, 1, name)

            await api.setRevokeBehavior(behavior)
            pairing.refreshStatus()
            await waitUntil { store.pending.isEmpty }

            XCTAssertTrue(store.pending.isEmpty, name)
            XCTAssertNil(pairing.revocationNotice, name)
            XCTAssertEqual(pairing.status, .notPaired, name)
            let calls = await api.calls
            XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer), .revoke(fakeDeviceToken, fakeServer)], name)
        }
    }

    func testSignedOutForegroundDoesNotRetryPendingRevocations() async throws {
        let api = MockDevicePairingAPI()
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let app = AppState(api: MockHestiaAPI(), receiptPairing: pairing, events: noEvents)
        await app.signOut()
        let pending = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        try store.savePendingRevocations([pending])

        app.enterForeground()
        XCTAssertNil(pairing.revocationNotice)
        try await waitUntil("the signed-out probe") { app.serverFeatures == .legacy }

        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.pending, [pending])
    }

    func testRefreshKeepsPendingRevocationAfterAnotherFailure() async throws {
        for behavior in [MockDevicePairingAPI.RevokeBehavior.offline, .unauthorized, .notFound, .disabled, .invalid, .unavailable] {
            let api = MockDevicePairingAPI(failRevoke: true)
            let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
            let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
            try await pairing.unpair()

            await api.setRevokeBehavior(behavior)
            pairing.refreshStatus()
            await waitForRevokeCount(2, api: api)

            XCTAssertEqual(store.pending, [.init(server: fakeServer, credential: fakeDeviceToken)])
            XCTAssertNil(pairing.credential(for: fakeServer))
            XCTAssertNotNil(pairing.revocationNotice)
        }
    }

    func testPendingRevocationRetriesOnlyAgainstOriginalServer() async throws {
        let otherServer = URL(string: "https://other.example")!
        var currentServer = fakeServer
        let api = MockDevicePairingAPI(failRevoke: true)
        let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { currentServer })
        try await pairing.unpair()

        currentServer = otherServer
        await api.setRevokeBehavior(.success)
        pairing.refreshStatus()
        await waitUntil { store.pending.isEmpty }

        let calls = await api.calls
        XCTAssertEqual(calls, [.revoke(fakeDeviceToken, fakeServer), .revoke(fakeDeviceToken, fakeServer)])
        XCTAssertNil(pairing.credential(for: otherServer))
    }

    func testPendingRevocationsAreBounded() throws {
        let store = MemoryDeviceTokenStore()
        for index in 0..<6 {
            try store.addPendingRevocation(.init(
                server: fakeServer,
                credential: .init(token: "token-\(index)", tokenID: "id-\(index)", expiresAt: .string("expiry"))
            ))
        }

        XCTAssertEqual(store.pending.count, 5)
        XCTAssertEqual(store.pending.map(\.credential.tokenID), ["id-1", "id-2", "id-3", "id-4", "id-5"])
    }

    func testPendingRevocationDoesNotBlockNewPairing() async throws {
        let old = StoredReceiptDeviceToken(
            server: fakeServer,
            credential: .init(token: "old-token", tokenID: "old-id", expiresAt: .string("old-expiry"))
        )
        let store = MemoryDeviceTokenStore()
        try store.addPendingRevocation(old)
        let api = MockDevicePairingAPI(failRevoke: true)
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        XCTAssertFalse(pairing.isBusy)

        let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
        try await pairing.pair(code: code, deviceName: "iPhone")
        await waitForRevokeCount(1, api: api)

        XCTAssertEqual(pairing.status, .paired)
        XCTAssertEqual(store.load()?.credential, fakeDeviceToken)
        XCTAssertEqual(store.pending, [old])
        XCTAssertNotNil(pairing.revocationNotice)
    }

    func testLateRedeemRevokeFailureLeavesPendingRevocation() async throws {
        let api = MockDevicePairingAPI(failRevoke: true, holdRedeem: true)
        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        await hestia.setAuthOff()
        let app = AppState(api: hestia, receiptPairing: pairing, events: noEvents)
        await app.connect()
        let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
        let redeem = Task { try await pairing.pair(code: code, deviceName: "iPhone") }
        while await api.calls.isEmpty { await Task.yield() }

        await app.signOut()
        await api.releaseRedeem()
        do {
            try await redeem.value
            XCTFail("Expected the pairing to be canceled")
        } catch is CancellationError {}

        XCTAssertNil(store.load())
        XCTAssertEqual(store.pending, [.init(server: fakeServer, provenance: .legacyCodeRedeem,
                                              credential: fakeDeviceToken)])
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertNotNil(pairing.revocationNotice)
    }

    func testStorageFailureRevokeFailureLeavesPendingRevocation() async throws {
        let api = MockDevicePairingAPI(failRevoke: true)
        let store = MemoryDeviceTokenStore()
        store.failNextSave()
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))

        do {
            try await pairing.pair(code: code, deviceName: "iPhone")
            XCTFail("Expected credential storage to fail")
        } catch DevicePairingError.storage {}

        XCTAssertNil(store.load())
        XCTAssertEqual(store.pending, [.init(server: fakeServer, provenance: .legacyCodeRedeem,
                                              credential: fakeDeviceToken)])
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertNotNil(pairing.revocationNotice)
    }

    func testLateUnauthorizedResponseDoesNotClearReplacementCredential() throws {
        let original = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let store = MemoryDeviceTokenStore(original)
        let pairing = ReceiptPairing(store: store, serverURL: { fakeServer })
        let replacement = StoredReceiptDeviceToken(server: fakeServer, credential:
            .init(token: "fake-replacement", tokenID: "fake-replacement-id", expiresAt: .number(123.5)))
        try store.save(replacement)
        pairing.invalidate(original)
        XCTAssertEqual(pairing.credential(for: fakeServer), replacement)
        XCTAssertEqual(pairing.status, .paired)
    }
}


@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
    XCTFail("Timed out waiting for pending revocation state", file: file, line: line)
}

@MainActor
private func waitForRevokeCount(
    _ expected: Int,
    api: MockDevicePairingAPI,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200 {
        let calls = await api.calls
        let count = calls.filter {
            if case .revoke = $0 { true } else { false }
        }.count
        if count >= expected { return }
        await Task.yield()
    }
    XCTFail("Timed out waiting for revoke request", file: file, line: line)
}

@MainActor
extension DevicePairingTests {
    @MainActor
    private struct ExchangeFixture {
        static let supported = ServerFeatures(authContract: 2, features: [.capabilities, .deviceExchange],
                                              qrOrigin: nil, isLegacy: false)
        static let rolledBack = ServerFeatures(authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false)
        static let deviceName = "Test iPhone"
        static let ownerKey = String(repeating: "a", count: 43)
        static let add = Permission.budgetReceiptsAdd.rawValue

        let defaults: UserDefaults
        let suite = "device-exchange-\(UUID())"
        let keychain = TestSessionKeychain()
        let sessionStore: CredentialSessionStore
        let session: BoundSession
        let store: MemoryDeviceTokenStore
        let api = MockDevicePairingAPI()

        init(provenance: DeviceTokenProvenance? = .legacyCodeRedeem, actor: String = "owner") throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            sessionStore = CredentialSessionStore(backendURLStore: BackendURLStore(userDefaults: defaults), keychain: keychain)
            let session = try sessionStore.commitAuthoritative(origin: fakeServer, actor: actor, token: "v2.test.mac")
            self.session = session
            store = MemoryDeviceTokenStore(provenance.map {
                let code = $0 == .legacyCodeRedeem
                let exchanged = $0 == .exchanged
                return .init(server: fakeServer, provenance: $0,
                             actor: code ? nil : actor, owner: exchanged ? actor : nil,
                             ownerKey: exchanged ? Self.ownerKey : nil,
                             issuedPermissions: exchanged ? [Self.add] : nil,
                             lastUsableCeiling: exchanged ? [Self.add] : nil,
                             sessionCommitID: code ? session.commitID : nil,
                             credential: fakeDeviceToken)
            })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }

        func pairing(features: ServerFeatures = Self.supported, grants: Capabilities? = nil,
                     sessionStore: CredentialSessionStore? = nil) -> ReceiptPairing {
            let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
            pairing.bindSessionStore(sessionStore ?? self.sessionStore)
            pairing.setServerFeatures(features, capabilities: grants ?? Self.owner())
            pairing.refreshStatus()
            return pairing
        }

        static func owner(budget: Bool = false) -> Capabilities {
            Capabilities(user: "owner", ownBudget: .init(
                permissions: budget ? [.budgetReceiptsAdd, .budgetView] : [.budgetReceiptsAdd],
                canView: budget, canUseReceipts: true, canManageDevices: true
            ))
        }

        static func delegate() -> Capabilities {
            Capabilities(user: "delegate", delegatedReceipts: .init(permissions: [.budgetReceiptsAdd], canUse: true))
        }

        static func reply(actor: String = "owner", owner: String = "owner", key: String = Self.ownerKey,
                          tokenID: String = fakeDeviceToken.tokenID,
                          permissions: [String] = [Self.add]) -> ExchangedDeviceToken {
            .init(credential: .init(token: "fake-exchanged-device-token", tokenID: tokenID, expiresAt: .string("new-expiry")),
                  scope: permissions.contains(Permission.budgetView.rawValue) ? .device : .receipts,
                  actor: actor, owner: owner, ownerKey: key, issuedPermissions: permissions)
        }

        func journal(_ state: RotationJournalState, replacement: StoredReceiptDeviceToken? = nil) throws -> RotationJournalRecord {
            let prior = try XCTUnwrap(store.load())
            return .init(state: state, server: fakeServer, capturedActor: try XCTUnwrap(session.actor),
                         expectedOwnerKey: prior.ownerKey, slotTokenID: prior.credential.tokenID,
                         priorToken: prior, replacement: replacement)
        }

        func exchange(_ pairing: ReceiptPairing, grants: Capabilities? = nil,
                      reason: ReceiptPairing.ExchangeReason = .automatic) async throws {
            try await pairing.exchange(session: session, capabilities: grants ?? Self.owner(), deviceName: Self.deviceName,
                                       reason: reason)
        }

        var proofCall: MockDevicePairingAPI.Call { .exchange(session, Self.deviceName, fakeDeviceToken) }
        var freshCall: MockDevicePairingAPI.Call { .exchange(session, Self.deviceName, nil) }
    }

    func testPreSendDeathOnIntentJournalKeepsPriorTokenActive() async throws {
        let f = try ExchangeFixture()
        defer { f.cleanUp() }
        let journal = try f.journal(.intent)
        f.store.saveRotationJournal([journal])

        let pairing = f.pairing()
        XCTAssertEqual(pairing.credential(for: fakeServer), journal.priorToken)
        XCTAssertEqual(f.store.load(), journal.priorToken)
        XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
        let calls = await f.api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testLostSuccessTimeoutSetsOutcomeUnknownQuarantinesPriorAndResolvesOnRetry() async throws {
        let f = try ExchangeFixture()
        defer { f.cleanUp() }
        let original = try XCTUnwrap(f.store.load())
        let replacement = ExchangeFixture.reply()
        await f.api.setExchangeResults([.failure(URLError(.timedOut)), .success(replacement)])
        let first = f.pairing()
        do {
            try await f.exchange(first)
            XCTFail("Expected the exchange to time out")
        } catch {}
        XCTAssertEqual(f.store.loadRotationJournal().first?.state, .outcomeUnknown)
        XCTAssertEqual(f.store.loadRotationJournal().first?.priorToken, original)
        XCTAssertNil(first.credential(for: fakeServer))

        let restarted = f.pairing()
        XCTAssertNil(restarted.credential(for: fakeServer))
        try await f.exchange(restarted)
        XCTAssertEqual(restarted.credential(for: fakeServer)?.credential, replacement.credential)
        XCTAssertEqual(f.store.load()?.provenance, .exchanged)
        XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
        let calls = await f.api.calls
        XCTAssertEqual(calls, [f.proofCall, f.proofCall])
    }

    func testLostSuccessOutcomeUnknownFollowedBy401Or403PersistsJournalAndQuarantineAcrossRestart() async throws {
        for denial in [DeviceExchangeError.http(status: 401, code: nil), .http(status: 403, code: "budget_forbidden")] {
            let f = try ExchangeFixture()
            defer { f.cleanUp() }
            let sent = try f.journal(.sent)
            f.store.saveRotationJournal([sent])
            await f.api.setExchangeResults([.failure(denial), .success(ExchangeFixture.reply())])

            let pairing = f.pairing()
            XCTAssertEqual(f.store.loadRotationJournal().first?.state, .outcomeUnknown)
            do {
                try await f.exchange(pairing)
                XCTFail("Expected the exchange denial")
            } catch {}
            let retried = f.pairing()
            XCTAssertNil(retried.credential(for: fakeServer))
            XCTAssertEqual(f.store.loadRotationJournal().first?.state, .outcomeUnknown)
            XCTAssertEqual(f.store.loadRotationJournal().first?.priorToken, sent.priorToken)

            try await f.exchange(retried)
            XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [f.proofCall, f.proofCall])
        }
    }

    func testOutcomeUnknownJournalWithMismatchedOriginOrActorDoesNotRetryOrPromoteWrongSession() async throws {
        let otherOrigin = try XCTUnwrap(URL(string: "https://hestia.example:8443"))
        for (origin, actor) in [(fakeServer, "other"), (otherOrigin, "owner")] {
            for state in [RotationJournalState.outcomeUnknown, .replaced] {
                let f = try ExchangeFixture(provenance: .exchanged)
                defer { f.cleanUp() }
                let prior = try XCTUnwrap(f.store.load())
                let replacement = StoredReceiptDeviceToken(
                    server: fakeServer, provenance: .exchanged, actor: "owner", owner: "owner",
                    ownerKey: ExchangeFixture.ownerKey, issuedPermissions: [ExchangeFixture.add],
                    credential: ExchangeFixture.reply().credential
                )
                let journal = try f.journal(state, replacement: state == .replaced ? replacement : nil)
                f.store.saveRotationJournal([journal])
                let changed = try f.sessionStore.commitAuthoritative(origin: origin, actor: actor, token: "v2.other.mac")
                let grants = actor == "owner" ? ExchangeFixture.owner() : Capabilities(
                    user: actor, ownBudget: .init(permissions: [.budgetReceiptsAdd], canView: false,
                                                 canUseReceipts: true, canManageDevices: true)
                )
                let pairing = f.pairing(grants: grants)
                XCTAssertNil(pairing.credential(for: origin))
                XCTAssertEqual(f.store.load(), prior)
                XCTAssertEqual(f.store.loadRotationJournal(), [journal])
                await f.api.setExchangeResults([.failure(DeviceExchangeError.http(status: 401, code: nil))])
                try? await pairing.exchange(session: changed, capabilities: grants, deviceName: ExchangeFixture.deviceName)
                let calls = await f.api.calls
                XCTAssertTrue(calls.allSatisfy { $0 == .exchange(changed, ExchangeFixture.deviceName, nil) })
                XCTAssertEqual(f.store.loadRotationJournal(), [journal])
                XCTAssertEqual(f.store.load(), prior)
            }
        }
    }

    func testFull5SlotSetStopsRetryingAndPreservesDeviceIdentifyingInfo() async throws {
        for (isOwner, actor) in [(true, "owner"), (false, "delegate")] {
            let f = try ExchangeFixture(provenance: isOwner ? .legacyCodeRedeem : nil, actor: actor)
            defer { f.cleanUp() }
            let grants = isOwner ? ExchangeFixture.owner() : ExchangeFixture.delegate()
            let first = f.pairing(grants: grants)
            await f.api.setExchangeResults([.failure(DeviceExchangeError.http(status: 409, code: "device_token_limit_reached"))])
            do {
                try await f.exchange(first, grants: grants)
                XCTFail("Expected a full device list")
            } catch DevicePairingError.deviceLimit {}
            let restarted = f.pairing(grants: grants)
            let info = try XCTUnwrap(restarted.deviceLimit)
            XCTAssertEqual(info.actor, actor)
            XCTAssertEqual(info.deviceName, ExchangeFixture.deviceName)
            XCTAssertEqual(info.tokenID, isOwner ? fakeDeviceToken.tokenID : nil)
            XCTAssertEqual(info.isOwner, isOwner)
            let notice = try XCTUnwrap(restarted.pairingNotice)
            XCTAssertEqual(notice.key, isOwner
                           ? "hestia already has 5 paired devices. Remove one in hestia’s device list."
                           : "hestia already has 5 paired devices. Ask the ledger owner to remove one.")
            try await f.exchange(restarted, grants: grants)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [isOwner ? f.proofCall : f.freshCall])
        }
    }

    func testDeathAfter401Or403ClearsJournalAndKeepsPriorTokenUnchanged() async throws {
        for denial in [DeviceExchangeError.http(status: 401, code: nil), .http(status: 403, code: "budget_forbidden")] {
            let f = try ExchangeFixture()
            defer { f.cleanUp() }
            let original = try XCTUnwrap(f.store.load())
            let first = f.pairing()
            await f.api.setExchangeResults([.failure(denial)])
            do {
                try await f.exchange(first)
                XCTFail("Expected the exchange denial")
            } catch {}
            XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
            XCTAssertEqual(first.credential(for: fakeServer), original)
            XCTAssertEqual(f.pairing().credential(for: fakeServer), original)
            XCTAssertTrue(f.store.pending.isEmpty)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [f.proofCall])
        }
    }

    func testProofBearing200AnomalyActorOwnerKeyOrTokenIDMismatchQuarantinesNewAndKeepsOld() async throws {
        for result in [
            ExchangeFixture.reply(actor: "other"),
            ExchangeFixture.reply(key: String(repeating: "b", count: 43)),
            ExchangeFixture.reply(tokenID: "different-id"),
        ] {
            let f = try ExchangeFixture(provenance: .exchanged)
            defer { f.cleanUp() }
            let original = try XCTUnwrap(f.store.load())
            let pairing = f.pairing()
            await f.api.setExchangeResults([.success(result)])
            try? await f.exchange(pairing, reason: .manual)
            XCTAssertEqual(f.store.load(), original)
            XCTAssertEqual(f.store.loadUntrustedExchangeTokens().map(\.credential), [result.credential])
            XCTAssertTrue(f.store.pending.isEmpty)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [f.proofCall])
        }
    }

    func testPriorToken409PriorInvalidFreshExchangeAndRevokesOldWithFullBearerAndOrigin() async throws {
        let f = try ExchangeFixture()
        defer { f.cleanUp() }
        let result = ExchangeFixture.reply(tokenID: "fresh-id")
        await f.api.setExchangeResults([
            .failure(DeviceExchangeError.http(status: 409, code: "device_token_prior_invalid")), .success(result),
        ])
        let pairing = f.pairing()
        try await f.exchange(pairing)
        XCTAssertEqual(pairing.credential(for: fakeServer)?.credential, result.credential)
        XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
        XCTAssertTrue(f.store.pending.isEmpty)
        XCTAssertEqual(pairing.pairingNotice?.key, "This iPhone was paired as a new device.")
        XCTAssertTrue(pairing.showNewDeviceAlert)
        let calls = await f.api.calls
        XCTAssertEqual(calls, [f.proofCall, f.freshCall, .revoke(fakeDeviceToken, fakeServer)])
    }

    func testReplacedJournalPromotesOnRestartAfterActiveStoreWriteFails() async throws {
        let f = try ExchangeFixture()
        defer { f.cleanUp() }
        let pairing = f.pairing()
        let result = ExchangeFixture.reply()
        await f.api.setExchangeResults([.success(result)])
        f.store.failNextSave()
        do {
            try await f.exchange(pairing)
            XCTFail("Expected active-slot persistence to fail")
        } catch DevicePairingError.storage {}
        XCTAssertEqual(f.store.loadRotationJournal().first?.state, .replaced)
        XCTAssertEqual(f.store.loadRotationJournal().first?.replacement?.credential, result.credential)
        XCTAssertNil(pairing.credential(for: fakeServer))

        let restarted = f.pairing()
        XCTAssertEqual(restarted.credential(for: fakeServer)?.credential, result.credential)
        XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
        let calls = await f.api.calls
        XCTAssertEqual(calls, [f.proofCall])
    }

    func testDeviceEligibleCeilingTracksBudgetViewSeparatelyFromReceiptAccess() async throws {
        let f = try ExchangeFixture(provenance: .exchanged)
        defer { f.cleanUp() }
        let grants = ExchangeFixture.owner(budget: true)
        let budgetOnly = Capabilities(user: "owner", ownBudget: .init(
            permissions: [.budgetView], canView: true, canUseReceipts: false, canManageDevices: true
        ))
        XCTAssertFalse(budgetOnly.canUseReceipts)
        XCTAssertEqual(budgetOnly.effectiveDeviceEligiblePermissions, [.budgetView])
        await f.api.setExchangeResults([.success(ExchangeFixture.reply(
            permissions: [ExchangeFixture.add, Permission.budgetView.rawValue, Permission.budgetEdit.rawValue]
        ))])
        let pairing = f.pairing(grants: grants)
        try await f.exchange(pairing, grants: grants, reason: .ceilingExpansion)
        let usable = try XCTUnwrap(pairing.credential(for: fakeServer))
        XCTAssertEqual(Set(usable.lastUsableCeiling ?? []), [ExchangeFixture.add, Permission.budgetView.rawValue])
        try await f.exchange(pairing, grants: grants, reason: .ceilingExpansion)
        let calls = await f.api.calls
        XCTAssertEqual(calls, [f.proofCall])
    }

    func testRollbackQuarantineSeparatesPR3TokenFromLegacySlot() async throws {
        for probeFirst in [true, false] {
            let f = try ExchangeFixture(provenance: .exchanged)
            defer { f.cleanUp() }
            let exchanged = try XCTUnwrap(f.store.load())
            let pairing = f.pairing()
            XCTAssertEqual(pairing.credential(for: fakeServer), exchanged)
            if probeFirst {
                pairing.setServerFeatures(ExchangeFixture.rolledBack, capabilities: ExchangeFixture.owner())
                XCTAssertNil(pairing.handleTokenRejection(exchanged, status: 401, code: "device_token_invalid"))
            } else {
                XCTAssertEqual(pairing.handleTokenRejection(exchanged, status: 401, code: "device_token_invalid"), .rollback)
                XCTAssertNil(pairing.credential(for: fakeServer))
                pairing.setServerFeatures(ExchangeFixture.rolledBack, capabilities: ExchangeFixture.owner())
            }
            XCTAssertEqual(f.store.loadRollbackQuarantine(), [exchanged])
            XCTAssertTrue(f.store.pending.isEmpty)
            XCTAssertNil(f.store.load())

            let restarted = f.pairing(features: ExchangeFixture.rolledBack)
            let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
            try await restarted.pair(code: code, deviceName: ExchangeFixture.deviceName)
            XCTAssertEqual(restarted.credential(for: fakeServer)?.provenance, .legacyCodeRedeem)
            XCTAssertEqual(f.store.loadRollbackQuarantine(), [exchanged])
            let calls = await f.api.calls
            XCTAssertEqual(calls, [.redeem(code, ExchangeFixture.deviceName, fakeServer)])
        }
    }

    func testInstalledOwnerMigratesLegacyTokenAtBootstrapAndRetainsItAcrossFailures() async throws {
        for provenance in [DeviceTokenProvenance.legacyCodeRedeem, .legacyMigrated1x] {
            let f = try ExchangeFixture(provenance: provenance)
            defer { f.cleanUp() }
            let before = try XCTUnwrap(f.store.load())
            let api = MockHestiaAPI()
            await api.setFeatures(ExchangeFixture.supported)
            await api.setCapabilities(ExchangeFixture.owner())
            let store = f.sessionStore
            let pairing = ReceiptPairing(api: f.api, store: f.store, serverURL: { fakeServer })
            let app = AppState(api: api, receiptPairing: pairing, sessionStore: store, events: noEvents)
            let result = ExchangeFixture.reply()
            await f.api.setExchangeResults([
                .failure(DeviceExchangeError.http(status: 401, code: nil)),
                .failure(DeviceExchangeError.http(status: 403, code: "budget_forbidden")),
                .failure(DeviceExchangeError.http(status: 503, code: nil)),
                .failure(URLError(.timedOut)),
                .failure(DeviceExchangeError.http(status: 401, code: nil)),
                .success(result),
            ])

            await app.bootstrap()
            XCTAssertEqual(app.phase, .ready)
            XCTAssertTrue(pairing.requiresExchangeSignIn)
            XCTAssertEqual(pairing.credential(for: fakeServer), before)
            await app.refresh()
            XCTAssertEqual(pairing.credential(for: fakeServer), before)
            await app.refresh()
            XCTAssertNil(pairing.credential(for: fakeServer))
            XCTAssertEqual(f.store.loadRotationJournal().first?.priorToken, before)
            await app.refresh()
            await app.refresh()
            XCTAssertEqual(f.store.loadRotationJournal().first?.state, .outcomeUnknown)
            XCTAssertEqual(f.store.loadRotationJournal().first?.priorToken, before)

            let restartedStore = CredentialSessionStore(backendURLStore: store.backendURLStore, keychain: f.keychain)
            let restarted = ReceiptPairing(api: f.api, store: f.store, serverURL: { fakeServer })
            let restartedApp = AppState(api: api, receiptPairing: restarted, sessionStore: restartedStore, events: noEvents)
            await restartedApp.bootstrap()
            XCTAssertEqual(restarted.credential(for: fakeServer)?.credential, result.credential)
            XCTAssertTrue(f.store.loadRotationJournal().isEmpty)
            XCTAssertTrue(f.store.pending.isEmpty)
            let calls = await f.api.calls
            XCTAssertEqual(calls.count, 6)
            XCTAssertTrue(calls.allSatisfy { $0 == .exchange(f.session, ReceiptPairing.deviceName, before.credential) })
        }
    }

    func testInFlightExchangeDoesNotPublishAfterAccountOrOriginSwitch() async throws {
        let otherOrigin = try XCTUnwrap(URL(string: "https://hestia.example:8443"))
        for (origin, actor) in [(fakeServer, "other"), (otherOrigin, "owner")] {
            let f = try ExchangeFixture(provenance: .exchanged)
            defer { f.cleanUp() }
            let prior = try XCTUnwrap(f.store.load())
            let pairing = f.pairing()
            await f.api.setExchangeResults([.success(ExchangeFixture.reply())], holdFirst: true)
            let rotation = Task { try await f.exchange(pairing, reason: .manual) }
            try await waitUntil("exchange request is in flight") { await f.api.isExchangeHeld }
            XCTAssertEqual(f.store.loadRotationJournal().first?.state, .sent)
            try f.sessionStore.commitAuthoritative(origin: origin, actor: actor, token: "v2.other.mac")
            pairing.setServerFeatures(ExchangeFixture.supported, capabilities: ExchangeFixture.owner())
            await f.api.releaseExchange()
            do {
                try await rotation.value
                XCTFail("Expected stale publication to be discarded")
            } catch is CancellationError {}
            XCTAssertEqual(f.store.load(), prior)
            XCTAssertNil(pairing.credential(for: origin))
            XCTAssertTrue(f.store.pending.isEmpty)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [f.proofCall])
        }
    }

    func testFailedRevocationQueueKeepsFiveAndRestoresOverflowNotice() async throws {
        let f = try ExchangeFixture(provenance: nil)
        defer { f.cleanUp() }
        let pairing = f.pairing()
        await f.api.setRevokeBehavior(.unavailable)
        let detached = (1...6).map { index in
            StoredReceiptDeviceToken(server: fakeServer, credential: .init(
                token: "detached-test-token-\(index)", tokenID: "detached-id-\(index)", expiresAt: .string("test-expiry")
            ))
        }
        for token in detached {
            try await pairing.revokeDetached(token)
        }
        XCTAssertEqual(f.store.pending, Array(detached.suffix(5)))
        XCTAssertTrue(pairing.hasEvictedPendingRevocations)
        await f.api.setRevokeBehavior(.success)
        let restarted = f.pairing()
        await waitUntil { f.store.pending.isEmpty }
        XCTAssertTrue(restarted.hasEvictedPendingRevocations)
        XCTAssertNotNil(restarted.revocationNotice)
    }

    func testAppRuntime403RefreshesOnceAndRotatesOnlyForAnExpandedCeiling() async throws {
        for grantRemoved in [true, false] {
            let f = try ExchangeFixture(provenance: .exchanged)
            defer { f.cleanUp() }
            let api = MockHestiaAPI()
            await api.setFeatures(ExchangeFixture.supported)
            await api.setCapabilities(ExchangeFixture.owner())
            let pairing = f.pairing()
            let app = AppState(api: api, receiptPairing: pairing, sessionStore: f.sessionStore, events: noEvents)
            await app.bootstrap()
            let revised = grantRemoved ? Capabilities(user: "owner") : ExchangeFixture.owner(budget: true)
            await api.setCapabilities(revised)
            let replacement = ExchangeFixture.reply(permissions: [ExchangeFixture.add, Permission.budgetView.rawValue])
            await f.api.setExchangeResults([.success(replacement)])
            let receipts = try XCTUnwrap(app.receiptsAPI)
            do {
                _ = try await receipts.parseReceiptText("test", source: .paste)
                XCTFail("Expected the receipt denial")
            } catch ReceiptError.forbidden {}
            try await waitUntil("the denial refresh updates receipt access") {
                app.capabilities == revised && (grantRemoved || f.store.load()?.credential == replacement.credential)
            }
            let capabilityCalls = await api.count(.capabilities)
            let exchangeCalls = await f.api.calls
            XCTAssertEqual(capabilityCalls, 2)
            if grantRemoved {
                XCTAssertNil(app.receiptsAPI)
                XCTAssertTrue(exchangeCalls.isEmpty)
            } else {
                XCTAssertEqual(exchangeCalls, [.exchange(f.session, ReceiptPairing.deviceName, fakeDeviceToken)])
            }
        }
    }

    func testAppRuntimeExpiryRefreshesAndIssuesFreshWithoutRevokingOldBearer() async throws {
        let f = try ExchangeFixture(provenance: .exchanged)
        defer { f.cleanUp() }
        let api = MockHestiaAPI()
        await api.setFeatures(ExchangeFixture.supported)
        await api.setCapabilities(ExchangeFixture.owner())
        await api.setReceiptParseError(.expiredDeviceToken)
        let pairing = f.pairing()
        let app = AppState(api: api, receiptPairing: pairing, sessionStore: f.sessionStore, events: noEvents)
        await app.bootstrap()
        let replacement = ExchangeFixture.reply(tokenID: "fresh-id")
        await f.api.setExchangeResults([.success(replacement)])
        let receipts = try XCTUnwrap(app.receiptsAPI)
        do {
            _ = try await receipts.parseReceiptText("test", source: .paste)
            XCTFail("Expected the receipt token expiry")
        } catch ReceiptError.expiredDeviceToken {}
        try await waitUntil("the refreshed session has a new device token") { f.store.load()?.credential == replacement.credential }
        let capabilityCalls = await api.count(.capabilities)
        let exchangeCalls = await f.api.calls
        XCTAssertEqual(capabilityCalls, 2)
        XCTAssertEqual(exchangeCalls, [.exchange(f.session, ReceiptPairing.deviceName, nil)])
        XCTAssertTrue(f.store.pending.isEmpty)
    }

    func testAppRollbackQuarantinesBeforeCapabilityResponseOrAfterReceiptRejection() async throws {
        for probeFirst in [true, false] {
            let f = try ExchangeFixture(provenance: .exchanged)
            defer { f.cleanUp() }
            let prior = try XCTUnwrap(f.store.load())
            let api = MockHestiaAPI()
            await api.setFeatures(ExchangeFixture.supported)
            await api.setCapabilities(ExchangeFixture.owner())
            let pairing = f.pairing()
            let app = AppState(api: api, receiptPairing: pairing, sessionStore: f.sessionStore, events: noEvents)
            await app.bootstrap()
            await api.setFeatures(ExchangeFixture.rolledBack)
            await api.setHoldCapabilities()
            let receipts = try XCTUnwrap(app.receiptsAPI)
            let refresh: Task<Void, Never>?
            if probeFirst {
                refresh = Task { await app.refresh() }
            } else {
                refresh = nil
                await api.setReceiptParseError(.invalidDeviceToken)
                do {
                    _ = try await receipts.parseReceiptText("test", source: .paste)
                    XCTFail("Expected the receipt token to be rejected after rollback")
                } catch ReceiptError.invalidDeviceToken {}
            }
            try await waitUntil("the rollback capabilities request is in flight") { await api.isCapabilitiesHeld }
            XCTAssertNil(pairing.credential(for: fakeServer))
            XCTAssertEqual(f.store.loadRollbackQuarantine(), [prior])
            XCTAssertTrue(f.store.pending.isEmpty)
            if probeFirst {
                do {
                    _ = try await receipts.parseReceiptText("test", source: .paste)
                    XCTFail("Expected the old scope to be rejected before dispatch")
                } catch is CancellationError {}
            }
            await api.releaseCapabilities()
            await refresh?.value
            try await waitUntil("the rollback capabilities are published") { app.serverFeatures == ExchangeFixture.rolledBack }

            let code = try XCTUnwrap(ReceiptPairingCode("ABCD2345"))
            try await pairing.pair(code: code, deviceName: ExchangeFixture.deviceName)
            let calls = await f.api.calls
            XCTAssertEqual(calls, [.redeem(code, ExchangeFixture.deviceName, fakeServer)])
            XCTAssertEqual(pairing.credential(for: fakeServer)?.provenance, .legacyCodeRedeem)
            XCTAssertEqual(f.store.loadRollbackQuarantine(), [prior])
        }
    }
}
