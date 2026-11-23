import Foundation
import XCTest
@testable import Vesta

private let fakeServer = URL(string: "https://hestia.example")!
let fakeDeviceToken = ReceiptDeviceToken(token: "fake-device-token", tokenID: "fake-token-id", expiresAt: .string("fake-expiry"))

@MainActor
final class MemoryDeviceTokenStore: DeviceTokenStoring {
    private var token: StoredReceiptDeviceToken?
    private var shouldFailSave = false
    private(set) var pending: [StoredReceiptDeviceToken] = []

    init(_ token: StoredReceiptDeviceToken? = nil) { self.token = token }
    func load() -> StoredReceiptDeviceToken? { token }
    func failNextSave() { shouldFailSave = true }
    func save(_ token: StoredReceiptDeviceToken) throws {
        if shouldFailSave {
            shouldFailSave = false
            throw DevicePairingError.storage
        }
        self.token = token
    }
    func clear() { token = nil }
    func loadPendingRevocations() -> [StoredReceiptDeviceToken] { pending }
    func savePendingRevocations(_ tokens: [StoredReceiptDeviceToken]) { pending = tokens }
}

private actor MockDevicePairingAPI: DevicePairingAPI {
    enum Call: Equatable {
        case redeem(ReceiptPairingCode, String, URL)
        case revoke(ReceiptDeviceToken, URL)
    }
    enum RevokeBehavior: Sendable {
        case success, offline, expired, revoked, notFound, disabled, unauthorized
    }

    private(set) var calls: [Call] = []
    private var revokeBehavior: RevokeBehavior
    private var holdRedeem: Bool
    private var redeemGate: CheckedContinuation<Void, Never>?

    init(failRevoke: Bool = false, holdRedeem: Bool = false) {
        revokeBehavior = failRevoke ? .offline : .success
        self.holdRedeem = holdRedeem
    }

    func setRevokeBehavior(_ behavior: RevokeBehavior) {
        revokeBehavior = behavior
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

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        calls.append(.revoke(token, server))
        switch revokeBehavior {
        case .success: break
        case .offline: throw URLError(.notConnectedToInternet)
        case .expired: throw ReceiptError.from(status: 401, code: "device_token_expired")
        case .revoked: throw ReceiptError.from(status: 401, code: "device_token_revoked")
        case .notFound: throw ReceiptError.from(status: 404, code: nil)
        case .disabled: throw ReceiptError.from(status: 404, code: "budget_receipts_disabled")
        case .unauthorized: throw ReceiptError.from(status: 401, code: nil)
        }
    }
}

private final class DevicePairingURLProtocol: URLProtocol, @unchecked Sendable {
    static let rateLimitedCode = "23456789"

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
        let restored = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        XCTAssertEqual(restored.status, .paired)
        XCTAssertEqual(restored.credential(for: fakeServer)?.credential, fakeDeviceToken)

        let otherServer = URL(string: "https://other.example")!
        let other = ReceiptPairing(api: api, store: store, serverURL: { otherServer })
        XCTAssertEqual(other.status, .notPaired)
        XCTAssertNil(other.credential(for: otherServer))
        XCTAssertNil(other.credential(for: fakeServer))
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

    func testSignOutRevokesAndClearsEvenWhenOffline() async {
        let api = MockDevicePairingAPI(failRevoke: true)
        let store = MemoryDeviceTokenStore(.init(server: fakeServer, credential: fakeDeviceToken))
        let pairing = ReceiptPairing(api: api, store: store, serverURL: { fakeServer })
        let hestia = MockHestiaAPI()
        let app = AppState(api: hestia, receiptPairing: pairing)

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
        let app = AppState(api: MockHestiaAPI(), receiptPairing: pairing)
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

    func testRefreshRetriesAndClearsPendingRevocationOnTerminalResults() async throws {
        let behaviors: [(MockDevicePairingAPI.RevokeBehavior, String)] = [
            (.success, "success"),
            (.expired, "expired"),
            (.revoked, "revoked"),
            (.notFound, "not found"),
            (.disabled, "receipts disabled"),
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

    func testRefreshKeepsPendingRevocationAfterAnotherFailure() async throws {
        for behavior in [MockDevicePairingAPI.RevokeBehavior.offline, .unauthorized] {
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
        let app = AppState(api: MockHestiaAPI(), receiptPairing: pairing)
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
        XCTAssertEqual(store.pending, [.init(server: fakeServer, credential: fakeDeviceToken)])
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
        XCTAssertEqual(store.pending, [.init(server: fakeServer, credential: fakeDeviceToken)])
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
