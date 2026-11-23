import Foundation
import XCTest
@testable import Vesta

private let fakeServer = URL(string: "https://hestia.example")!
let fakeDeviceToken = ReceiptDeviceToken(token: "fake-device-token", tokenID: "fake-token-id", expiresAt: .string("fake-expiry"))

@MainActor
final class MemoryDeviceTokenStore: DeviceTokenStoring {
    private var token: StoredReceiptDeviceToken?

    init(_ token: StoredReceiptDeviceToken? = nil) { self.token = token }
    func load() -> StoredReceiptDeviceToken? { token }
    func save(_ token: StoredReceiptDeviceToken) { self.token = token }
    func clear() { token = nil }
}

private actor MockDevicePairingAPI: DevicePairingAPI {
    enum Call: Equatable {
        case redeem(ReceiptPairingCode, String, URL)
        case revoke(ReceiptDeviceToken, URL)
    }

    private(set) var calls: [Call] = []
    private let failRevoke: Bool
    private var holdRedeem: Bool
    private var redeemGate: CheckedContinuation<Void, Never>?

    init(failRevoke: Bool = false, holdRedeem: Bool = false) {
        self.failRevoke = failRevoke
        self.holdRedeem = holdRedeem
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
        if failRevoke { throw URLError(.notConnectedToInternet) }
    }
}

private final class DevicePairingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.host, fakeServer.host)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)

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
            switch url.path {
            case "/api/budget/receipts/device-token/redeem":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(json, ["code": "ABCD2345", "device_name": "iPhone"])
                responseBody = #"{"token":"fake-device-token","token_id":"fake-token-id","scope":"fake-scope","expires_at":123.5}"#
                status = 200
            case "/api/budget/receipts/device-token/revoke":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-device-token")
                XCTAssertEqual(json, ["token_id": "fake-token-id"])
                responseBody = ""
                status = 204
            default:
                XCTFail("Unexpected pairing endpoint")
                responseBody = ""
                status = 404
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
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
        for input in ["ABCD234", "ABCD23456", "ABCU2345", "ABCİ2345", "ABCD2345!", ""] {
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

    func testRedeemAndRevokeWireRequests() async throws {
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [DevicePairingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = URLSessionDevicePairingAPI(session: session)
        let code = try XCTUnwrap(ReceiptPairingCode("abcd-2345"))
        let token = try await api.redeem(code: code, deviceName: "iPhone", server: fakeServer)
        XCTAssertEqual(token.token, fakeDeviceToken.token)
        XCTAssertEqual(token.tokenID, fakeDeviceToken.tokenID)
        XCTAssertEqual(token.expiresAt, .number(123.5))
        try await api.revoke(token, server: fakeServer)
    }

    func testKeychainRoundTripReplacesAndRemovesCredential() throws {
        let store: any DeviceTokenStoring = KeychainDeviceTokenStore(account: "test-\(UUID())")
        defer { try? store.clear() }
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
            XCTAssertEqual(pairing.status, .notPaired)
        }
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
        XCTAssertEqual(app.phase, .needsAuth)
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

    func testLateUnauthorizedResponseDoesNotClearReplacementCredential() {
        let original = StoredReceiptDeviceToken(server: fakeServer, credential: fakeDeviceToken)
        let store = MemoryDeviceTokenStore(original)
        let pairing = ReceiptPairing(store: store, serverURL: { fakeServer })
        let replacement = StoredReceiptDeviceToken(server: fakeServer, credential:
            .init(token: "fake-replacement", tokenID: "fake-replacement-id", expiresAt: .number(123.5)))
        store.save(replacement)
        pairing.invalidate(original)
        XCTAssertEqual(pairing.credential(for: fakeServer), replacement)
        XCTAssertEqual(pairing.status, .paired)
    }
}
