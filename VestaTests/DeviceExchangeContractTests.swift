import Foundation
import HTTPTypes
import XCTest
@testable import Vesta

private let exchangeOrigin = URL(string: "https://hestia.example:8443")!

private final class DeviceExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    static let ownerKey = String(repeating: "a", count: 43)
    static let nativeSession = "v2.test.session"
    static let mergedStatusFixtures: [String: (status: Int, code: String)] = [
        "invalid-request": (400, "fixture_invalid_request"),
        "native-session-required": (401, "native_session_required"),
        "support-disabled": (404, "fixture_support_disabled"),
        "request-timeout": (408, "fixture_request_timeout"),
        "length-required": (411, "fixture_length_required"),
        "body-too-large": (413, "fixture_body_too_large"),
        "media-type": (415, "fixture_media_type"),
        "incompatible-bridge": (503, "fixture_incompatible_bridge"),
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertTrue(OriginMatcher.matches(url, exchangeOrigin))
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try requestBody()
            let status: Int
            let json: String
            switch url.path {
            case "/api/auth/device-token":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.nativeSession)")
                let name = try XCTUnwrap(body["device_name"])
                switch name {
                case "fresh":
                    XCTAssertEqual(body, ["device_name": "fresh"])
                    (status, json) = (200, success(tokenID: "new-token-id"))
                case "rotate":
                    XCTAssertEqual(body, ["device_name": "rotate", "prior_token": fakeDeviceToken.token])
                    (status, json) = (200, success(tokenID: fakeDeviceToken.tokenID))
                case "prior-invalid":
                    (status, json) = (409, #"{"error":{"code":"device_token_prior_invalid"}}"#)
                case "limit":
                    (status, json) = (409, #"{"error":{"code":"device_token_limit_reached"}}"#)
                case "misleading-flat-error":
                    (status, json) = (409, #"{"error":"device_token_prior_invalid"}"#)
                case "empty-denial":
                    (status, json) = (401, "")
                default:
                    if let fixture = Self.mergedStatusFixtures[name] {
                        XCTAssertEqual(body, ["device_name": name, "prior_token": fakeDeviceToken.token])
                        (status, json) = (fixture.status, #"{"error":{"code":"\#(fixture.code)"}}"#)
                    } else {
                        XCTFail("Unexpected device name")
                        (status, json) = (400, "")
                    }
                }
            case "/api/budget/receipts/device-token/revoke":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(fakeDeviceToken.token)")
                switch body["token_id"] {
                case "successful": (status, json) = (200, "")
                case "expired": (status, json) = (401, #"{"ok":false,"error":"device_token_expired"}"#)
                case "invalid": (status, json) = (401, #"{"error":{"code":"device_token_invalid"}}"#)
                default: (status, json) = (404, "")
                }
            default:
                XCTFail("Unexpected device endpoint")
                (status, json) = (404, "")
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                       headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func requestBody() throws -> [String: String] {
        if let data = request.httpBody {
            return try JSONDecoder().decode([String: String].self, from: data)
        }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: stream) as? [String: String])
    }

    private func success(tokenID: String) -> String {
        """
        {"token":"replacement","token_id":"\(tokenID)","scope":"device","actor":"owner","owner":"owner",
         "owner_key":"\(Self.ownerKey)","issued_permissions":["budget.view"],"expires_at":"2027-02-21T18:00:00Z"}
        """
    }
}

@MainActor
final class DeviceExchangeContractTests: XCTestCase {
    private let bound = BoundSession(origin: exchangeOrigin, actor: "owner", token: DeviceExchangeURLProtocol.nativeSession)

    private func makeAPI() -> GeneratedDevicePairingAPI {
        let configuration = HTTPSession.featuresProbeConfiguration
        configuration.protocolClasses = [DeviceExchangeURLProtocol.self]
        return GeneratedDevicePairingAPI(session: URLSession(configuration: configuration))
    }

    func testExchangeWireCarriesPriorProofOnlyForRotation() async throws {
        let api = makeAPI()
        let rotated = try await api.exchange(session: bound, deviceName: "rotate", priorToken: fakeDeviceToken)
        XCTAssertEqual(rotated.credential.tokenID, fakeDeviceToken.tokenID)
        XCTAssertEqual(rotated.credential.expiresAt, .string("2027-02-21T18:00:00Z"))
        XCTAssertEqual(rotated.scope, .device)
        XCTAssertEqual(rotated.actor, "owner")
        XCTAssertEqual(rotated.owner, "owner")
        XCTAssertEqual(rotated.ownerKey, DeviceExchangeURLProtocol.ownerKey)
        XCTAssertEqual(rotated.issuedPermissions, [Permission.budgetView.rawValue])

        let fresh = try await api.exchange(session: bound, deviceName: "fresh", priorToken: nil)
        XCTAssertEqual(fresh.credential.tokenID, "new-token-id")
    }

    func testExchangePreservesStatusAndTrustsOnlyNestedConflictCodes() async {
        let api = makeAPI()
        let cases: [(String, DeviceExchangeError)] = [
            ("prior-invalid", .http(status: 409, code: "device_token_prior_invalid")),
            ("limit", .http(status: 409, code: "device_token_limit_reached")),
            ("misleading-flat-error", .http(status: 409, code: nil)),
            ("empty-denial", .http(status: 401, code: nil)),
        ]
        for (name, expected) in cases {
            do {
                _ = try await api.exchange(session: bound, deviceName: name, priorToken: fakeDeviceToken)
                XCTFail("Expected exchange error for \(name)")
            } catch {
                XCTAssertEqual(error as? DeviceExchangeError, expected)
            }
        }
    }

    func testExchangePreservesMergedStatusAndNestedAuthError() async {
        let api = makeAPI()
        for (name, fixture) in DeviceExchangeURLProtocol.mergedStatusFixtures {
            do {
                _ = try await api.exchange(session: bound, deviceName: name, priorToken: fakeDeviceToken)
                XCTFail("Expected an exchange error for HTTP \(fixture.status)")
            } catch {
                XCTAssertEqual(error as? DeviceExchangeError, .http(status: fixture.status, code: fixture.code))
            }
        }
    }

    func testExchangeMiddlewareRefusesABoundBearerAtAnotherOrigin() async {
        let other = URL(string: "https://hestia.example:9443")!
        let middleware = BearerAuthMiddleware(session: bound)
        let request = HTTPRequest(method: .post, scheme: other.scheme, authority: other.host, path: "/api/auth/device-token")
        let transport = CapturingTransport(status: 200, body: "{}")
        do {
            _ = try await middleware.intercept(request, body: nil, baseURL: other, operationID: Operations.ExchangeNativeSession.id) {
                request, body, origin in
                try await transport.send(request, body: body, baseURL: origin, operationID: Operations.ExchangeNativeSession.id)
            }
            XCTFail("Expected an origin rejection")
        } catch {
            XCTAssertEqual(error as? DeviceExchangeError, .invalidSession)
        }
        XCTAssertNil(transport.last)
    }

    func testSelfRevocationPreservesStatusAndExactErrorCode() async throws {
        let api = makeAPI()
        func revoke(_ id: String) async throws {
            let target = ReceiptDeviceToken(token: fakeDeviceToken.token, tokenID: id, expiresAt: fakeDeviceToken.expiresAt)
            try await api.revoke(target, server: exchangeOrigin)
        }
        try await revoke("successful")
        let cases: [(String, DeviceRevocationError)] = [
            ("expired", .http(status: 401, code: "device_token_expired")),
            ("invalid", .http(status: 401, code: "device_token_invalid")),
            ("not-found", .http(status: 404, code: nil)),
        ]
        for (name, expected) in cases {
            do {
                try await revoke(name)
                XCTFail("Expected revocation error for \(name)")
            } catch {
                XCTAssertEqual(error as? DeviceRevocationError, expected)
            }
        }
    }
}
