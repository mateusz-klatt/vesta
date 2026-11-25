import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession
import XCTest
@testable import Vesta

private let probeOrigin = URL(string: "https://hestia.example")!
private let featuresPath = "/api/auth/features"
private let capabilitiesPath = "/api/me/capabilities"
private let whoamiPath = "/api/whoami"

private actor AuthContractTransport: ClientTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String?

        init(_ status: Int, _ body: String? = nil) {
            self.status = status
            self.body = body
        }
    }

    struct Call: Equatable, Sendable {
        let path: String?
        let origin: URL
        let authorization: String?
    }

    private let replies: [String: Reply]
    private(set) var calls: [Call] = []

    init(_ replies: [String: Reply]) { self.replies = replies }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL,
              operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        calls.append(.init(path: request.path, origin: baseURL,
                           authorization: request.headerFields[.authorization]))
        let reply = request.path.flatMap { replies[$0] } ?? Reply(404)
        var response = HTTPResponse(status: .init(code: reply.status))
        guard let json = reply.body else { return (response, nil) }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }
}

private final class LegacyFeaturesURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url, probeOrigin.appending(path: featuresPath))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 401, httpVersion: nil,
                headerFields: ["Set-Cookie": "hestia_session=fake-cookie; Path=/; Secure"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FeaturesProbeTests: XCTestCase {
    func testFeaturesProbeUnauthenticatedOnLegacy0460Middleware() async throws {
        let configuration = HTTPSession.featuresProbeConfiguration
        configuration.protocolClasses = [LegacyFeaturesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
        let api = APIClient(transport: transport, sessionStore: try await testCredentialSessionStore(origin: probeOrigin, token: "fake-session-token"))

        let first = try await api.probeFeatures(on: probeOrigin)
        let second = try await api.probeFeatures(on: probeOrigin)

        XCTAssertEqual(first, .legacy)
        XCTAssertEqual(second, .legacy)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertEqual(session.configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(session.configuration.httpAdditionalHeaders?["Cache-Control"] as? String, "no-store")
    }

    func testLegacyFeaturesStatusesUseWhoamiOnly() async throws {
        for status in [401, 403, 404] {
            let transport = AuthContractTransport([
                featuresPath: .init(status),
                whoamiPath: .init(200, #"{"user":"viewer","role":"viewer"}"#),
            ])
            let api = APIClient(transport: transport, sessionStore: try await testCredentialSessionStore(origin: probeOrigin, token: "fake-session-token"))

            let probe = try await api.probeFeatures(on: probeOrigin)
            XCTAssertEqual(probe, .legacy)
            let capabilities = try await api.capabilities(on: probeOrigin, features: probe)
            XCTAssertEqual(capabilities, .fromLegacyRole(role: "viewer", user: "viewer"))
            let calls = await transport.calls
            XCTAssertEqual(calls, [
                .init(path: featuresPath, origin: probeOrigin, authorization: nil),
                .init(path: whoamiPath, origin: probeOrigin, authorization: "Bearer fake-session-token"),
            ])
        }
    }

    func testAdvertisedCapabilities403And404NeverFallBackToWhoami() async throws {
        let statuses: [(Int, APIError)] = [(403, .forbidden), (404, .http(404))]
        for (status, error) in statuses {
            let transport = AuthContractTransport([
                featuresPath: .init(200, #"{"auth_contract":2,"features":["capabilities"],"qr_origin":null}"#),
                capabilitiesPath: .init(status),
                whoamiPath: .init(200, #"{"user":"viewer","role":"viewer"}"#),
            ])
            let api = APIClient(transport: transport, sessionStore: try await testCredentialSessionStore(origin: probeOrigin, token: "fake-session-token"))

            let probe = try await api.probeFeatures(on: probeOrigin)
            XCTAssertTrue(probe.supports(.capabilities))
            await XCTAssertThrowsErrorEqual(try await api.capabilities(on: probeOrigin, features: probe), error)
            let calls = await transport.calls
            XCTAssertEqual(calls, [
                .init(path: featuresPath, origin: probeOrigin, authorization: nil),
                .init(path: capabilitiesPath, origin: probeOrigin, authorization: "Bearer fake-session-token"),
            ])
        }
    }

    func testFeaturesDecodeNullableQROriginAndIgnoreUnknownFeatures() async throws {
        let fixtureWithNull = #"{"auth_contract":2,"features":["capabilities","future_feature"],"qr_origin":null}"#
        let fixtureWithOrigin = """
        {
          "auth_contract": 3,
          "features": ["capabilities", "qr_login", "device_exchange", "calendar_instances",
                       "budget_native_read", "future_feature"],
          "qr_origin": "https://hestia.example"
        }
        """

        let withoutOrigin = try await decodeFeatures(fixtureWithNull)
        XCTAssertEqual(withoutOrigin, ServerFeatures(
            authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false
        ))
        let withOrigin = try await decodeFeatures(fixtureWithOrigin)
        XCTAssertEqual(withOrigin, ServerFeatures(
            authContract: 3, features: [.capabilities, .qrLogin, .deviceExchange, .calendarInstances, .budgetNativeRead],
            qrOrigin: probeOrigin, isLegacy: false
        ))
    }

    func testUnsupportedMalformedAndNon200FeaturesAreLegacy() async throws {
        let unsupported = try await decodeFeatures(#"{"auth_contract":1,"features":["capabilities"],"qr_origin":null}"#)
        XCTAssertEqual(unsupported, .legacy)
        let malformed = try await decodeFeatures(#"{"auth_contract":2,"features":false,"qr_origin":null}"#)
        XCTAssertEqual(malformed, .legacy)
        let non200 = try await decodeFeatures(#"{"auth_contract":2,"features":["capabilities"],"qr_origin":null}"#, status: 500)
        XCTAssertEqual(non200, .legacy)
    }

    func testProbeRethrowsURLError() async throws {
        let api = APIClient(transport: StubTransport { _ in throw URLError(.timedOut) })
        do {
            _ = try await api.probeFeatures(on: probeOrigin)
            XCTFail("Expected the network error to escape the probe")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    private func decodeFeatures(_ json: String, status: Int = 200) async throws -> ServerFeatures {
        let transport = AuthContractTransport([featuresPath: .init(status, json)])
        return try await APIClient(transport: transport).probeFeatures(on: probeOrigin)
    }
}

final class MeCapabilitiesContractTests: XCTestCase {
    func testOwnerDecodesWithIndependentBudgetFlagsAndUnknownPermissions() async throws {
        let capabilities = try await decodeCapabilities("""
        {
          "user": "owner",
          "actor_tag": "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
          "installation_permissions": ["ioc.view", "ioc.control", "calendar.view", "future.permission"],
          "own_budget": {
            "permissions": ["budget.view", "budget.receipts.add", "budget.receipts.view", "budget.receipts.edit",
                            "budget.receipts.match", "budget.future"],
            "can_view": true,
            "can_use_receipts": true,
            "can_manage_devices": false
          },
          "delegated_receipts": null,
          "household_available": false
        }
        """)

        XCTAssertEqual(capabilities.user, "owner")
        XCTAssertNil(capabilities.legacyRole)
        XCTAssertFalse(capabilities.isAuthOff)
        XCTAssertEqual(capabilities.installation, [.iocView, .iocControl, .calendarView])
        XCTAssertEqual(capabilities.ownBudget, .init(permissions: Permission.deviceEligibleIDs, canView: true,
                                                    canUseReceipts: true, canManageDevices: false))
        XCTAssertTrue(capabilities.canControlIOC)
        XCTAssertTrue(capabilities.canViewCalendar)
        XCTAssertTrue(capabilities.canUseReceipts)
        XCTAssertNil(capabilities.delegatedReceipts)
    }

    func testViewerDecodesWithNullBudgetScopes() async throws {
        let capabilities = try await decodeCapabilities("""
        {
          "user": "viewer",
          "actor_tag": "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
          "installation_permissions": ["ioc.view"],
          "own_budget": null,
          "delegated_receipts": null,
          "household_available": false
        }
        """)

        XCTAssertEqual(capabilities, Capabilities(user: "viewer", installation: [.iocView]))
        XCTAssertTrue(capabilities.canViewIOC)
        XCTAssertFalse(capabilities.canControlIOC)
        XCTAssertFalse(capabilities.canViewCalendar)
        XCTAssertFalse(capabilities.canUseReceipts)
    }

    func testAuthOffDecodesExplicitNullsAndUsesListedPermissions() async throws {
        let capabilities = try await decodeCapabilities("""
        {
          "user": null,
          "actor_tag": null,
          "installation_permissions": ["ioc.view", "ioc.control", "ioc.configure", "calendar.view",
                                       "calendar.edit", "system.audit.view", "household.view"],
          "own_budget": null,
          "delegated_receipts": null,
          "household_available": true
        }
        """)

        XCTAssertTrue(capabilities.isAuthOff)
        XCTAssertTrue(capabilities.householdAvailable)
        XCTAssertEqual(capabilities.installation, [
            .iocView, .iocControl, .iocConfigure, .calendarView, .calendarEdit, .systemAuditView, .householdView,
        ])
        XCTAssertNil(capabilities.user)
        XCTAssertNil(capabilities.legacyRole)
        XCTAssertNil(capabilities.ownBudget)
        XCTAssertNil(capabilities.delegatedReceipts)
    }

    func testDelegatedScopeIgnoresUnknownPermissions() async throws {
        let capabilities = try await decodeCapabilities("""
        {
          "user": "delegate",
          "actor_tag": "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
          "installation_permissions": [],
          "own_budget": null,
          "delegated_receipts": {"permissions": ["budget.receipts.add", "budget.future"], "can_use": true},
          "household_available": false
        }
        """)

        XCTAssertEqual(capabilities.delegatedReceipts, .init(permissions: [.budgetReceiptsAdd], canUse: true))
        XCTAssertTrue(capabilities.canUseReceipts)
        XCTAssertFalse(capabilities.canMatchReceipts)
        XCTAssertNil(capabilities.ownBudget)
    }

    private func decodeCapabilities(_ json: String) async throws -> Capabilities {
        let transport = AuthContractTransport([capabilitiesPath: .init(200, json)])
        let api = APIClient(transport: transport, sessionStore: try await testCredentialSessionStore(origin: probeOrigin, token: "fake-session-token"))
        let features = ServerFeatures(authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false)
        return try await api.capabilities(on: probeOrigin, features: features)
    }
}
