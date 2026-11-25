import Foundation
import OpenAPIURLSession
import os
import XCTest
@testable import Vesta

private let fakeQRCode = String(repeating: "A", count: 19)

final class QRLoginTests: XCTestCase {
    func testSharedHestiaAuthorityCanonicalizationAndRejectFixtures() {
        let maxOrigin = "https://" + String(repeating: "a", count: 29) + ".example"
        let accepted: [(raw: String, canonical: String)] = [
            ("https://hestia.example", "https://hestia.example"),
            ("https://HESTIA.Example:443", "https://hestia.example"),
            ("https://hestia-2.example:1", "https://hestia-2.example:1"),
            ("https://hestia.example:65535", "https://hestia.example:65535"),
            ("https://hestia", "https://hestia"),
            ("https://192.0.2.1:8443", "https://192.0.2.1:8443"),
            ("https://[2001:DB8::5]:443", "https://[2001:db8::5]"),
            ("https://[::ffff:192.0.2.1]:8443", "https://[::ffff:192.0.2.1]:8443"),
            (maxOrigin, maxOrigin),
        ]
        for fixture in accepted {
            let payload = QRLoginPayload(rawValue: "hestia-login:\(fixture.raw)#\(fakeQRCode)")
            XCTAssertEqual(payload?.origin.absoluteString, fixture.canonical, fixture.raw)
            XCTAssertTrue(payload?.code == fakeQRCode, fixture.raw)
        }

        let rejectedOrigins: [(reason: String, raw: String)] = [
            ("no origin", ""),
            ("no host", "https://"),
            ("non-HTTPS", "http://hestia.example"),
            ("scheme case", "HTTPS://hestia.example"),
            ("userinfo", "https://owner@hestia.example"),
            ("root path", "https://hestia.example/"),
            ("path", "https://hestia.example/path"),
            ("backslash", "https://hestia.example\\path"),
            ("query", "https://hestia.example?query"),
            ("fragment", "https://hestia.example#fragment"),
            ("escaped host", "https://hestia%2eexample"),
            ("whitespace", "https://hestia.example "),
            ("control character", "https://hestia\u{0000}.example"),
            ("DEL", "https://hestia\u{007f}.example"),
            ("non-ASCII", "https://héstia.example"),
            ("empty label", "https://hestia..example"),
            ("leading dot", "https://.hestia.example"),
            ("trailing dot", "https://hestia.example."),
            ("leading hyphen", "https://-hestia.example"),
            ("trailing hyphen", "https://hestia-.example"),
            ("underscore", "https://_hestia.example"),
            ("IPv4 out of range", "https://192.0.2.256"),
            ("IPv4 leading zero", "https://192.0.02.1"),
            ("IPv4 short form", "https://192.1"),
            ("IPv4 hex alias", "https://0xc0000201"),
            ("IPv6 without brackets", "https://2001:db8::5"),
            ("IPv6 invalid literal", "https://[2001:db8:::5]"),
            ("IPv6 with invalid IPv4 suffix", "https://[::ffff:192.0.02.1]"),
            ("IPv6 zone identifier", "https://[fe80::1%25en0]"),
            ("IPv6 trailing text", "https://[2001:db8::5]extra"),
            ("IPv6 missing bracket", "https://[2001:db8::5"),
            ("IPv6 empty port", "https://[2001:db8::5]:"),
            ("IPv4 in brackets", "https://[192.0.2.1]"),
            ("empty port", "https://hestia.example:"),
            ("zero port", "https://hestia.example:0"),
            ("port leading zero", "https://hestia.example:0443"),
            ("signed port", "https://hestia.example:+443"),
            ("port out of range", "https://hestia.example:65536"),
            ("too long", maxOrigin + "x"),
        ]
        for fixture in rejectedOrigins {
            XCTAssertNil(QRLoginPayload(rawValue: "hestia-login:\(fixture.raw)#\(fakeQRCode)"), fixture.reason)
        }

        let prefixAndOrigin = "hestia-login:https://hestia.example"
        let rejectedPayloads: [(reason: String, raw: String)] = [
            ("missing prefix", "https://hestia.example#\(fakeQRCode)"),
            ("prefix case", "Hestia-login:https://hestia.example#\(fakeQRCode)"),
            ("receipt pairing", "hestia-pair:https://hestia.example#\(fakeQRCode)"),
            ("missing separator", prefixAndOrigin + fakeQRCode),
            ("empty code", prefixAndOrigin + "#"),
            ("short code", prefixAndOrigin + "#" + fakeQRCode.dropLast()),
            ("padded code", prefixAndOrigin + "#" + fakeQRCode + "="),
            ("trailing newline", prefixAndOrigin + "#" + fakeQRCode + "\n"),
            ("base64 instead of base64url", prefixAndOrigin + "#" + fakeQRCode.dropLast() + "+"),
            ("non-zero unused bits", prefixAndOrigin + "#" + fakeQRCode.dropLast() + "B"),
        ]
        for fixture in rejectedPayloads {
            XCTAssertNil(QRLoginPayload(rawValue: fixture.raw), fixture.reason)
        }

        let urlSafeCode = "-_" + String(repeating: "A", count: 17)
        XCTAssertNotNil(QRLoginPayload(rawValue: prefixAndOrigin + "#" + urlSafeCode))
    }

    func testIsolatedTransportRejectsCookiesCredentialsRedirectsAndHTTPAuthChallenge() async throws {
        let production = HTTPSession.qrRedeem
        let configuration = production.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)

        let delegate = try XCTUnwrap(production.delegate as? UnauthenticatedAuthDelegate)
        let origin = URL(string: "https://hestia.example")!
        let url = origin.appending(path: "/api/auth/qr-redeem")
        let task = production.dataTask(with: url)
        defer { task.cancel() }
        for location in [origin.appending(path: "/redirect"), URL(string: "https://hestia.example:8443/redirect")!] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil,
                                                        headerFields: ["Location": location.absoluteString]))
            let redirected = await delegate.urlSession(production, task: task, willPerformHTTPRedirection: response,
                                                       newRequest: URLRequest(url: location))
            XCTAssertNil(redirected)
        }

        let methods: [(String, URLSession.AuthChallengeDisposition)] = [
            (NSURLAuthenticationMethodHTTPBasic, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodHTTPDigest, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodClientCertificate, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodServerTrust, .performDefaultHandling),
        ]
        for (method, expected) in methods {
            let protectionSpace = URLProtectionSpace(host: "hestia.example", port: 443, protocol: "https", realm: nil,
                                                     authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil,
                                                       previousFailureCount: 0, failureResponse: nil, error: nil,
                                                       sender: QRChallengeSender())
            let (sessionDisposition, sessionCredential) = await delegate.urlSession(production, didReceive: challenge)
            let (taskDisposition, taskCredential) = await delegate.urlSession(production, task: task, didReceive: challenge)
            XCTAssertEqual(sessionDisposition, expected, method)
            XCTAssertEqual(taskDisposition, expected, method)
            XCTAssertNil(sessionCredential, method)
            XCTAssertNil(taskCredential, method)
        }
    }

    func testRedeemWireTypesMatchPinnedContractFixtures() throws {
        let origin = "https://hestia.example"
        let request = QRLoginRequest(origin: origin, code: fakeQRCode)
        let requestJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        XCTAssertEqual(requestJSON as? [String: String], ["origin": origin, "code": fakeQRCode])

        let decoder = JSONDecoder()
        let response = try decoder.decode(QRLoginResponse.self, from: Data(MockQRLoginURLProtocol.Reply.success.body.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.user, "owner")
        XCTAssertTrue(response.token == "fake-session-token")

        let error = try decoder.decode(QRLoginErrorResponse.self, from: Data(#"{"error":{"code":"qr_invalid_request"}}"#.utf8))
        XCTAssertEqual(error.error.code, "qr_invalid_request")
    }

    func testRedeemMapsSanitizedErrorsAndSuccess() async throws {
        let origin = URL(string: "https://hestia.example:8443")!
        let errors: [(Int, String, QRLoginError)] = [
            (400, "qr_auth_ambiguous", .ambiguousAuth),
            (400, "qr_origin_mismatch", .originMismatch),
            (401, "qr_code_invalid", .invalidCode),
            (429, "qr_rate_limited", .rateLimited(retryAfter: nil)),
            (503, "auth_origin_unavailable", .originUnavailable),
            (400, "unexpected-echo", .failed),
        ]
        let replies = errors.map { status, code, _ in
            MockQRLoginURLProtocol.Reply(status, #"{"error":{"code":"\#(code)","detail":"fake-redacted-value"}}"#)
        }
        MockQRLoginURLProtocol.install(replies + [.init(200, "{}"), .success], at: origin)
        defer { MockQRLoginURLProtocol.remove(at: origin) }
        let session = Self.mockSession(for: HTTPSession.qrRedeem)
        defer { session.invalidateAndCancel() }
        let api = QRLoginAPI(session: session)

        for (_, _, expected) in errors {
            await assertRedeemFails(api, at: origin, with: expected)
        }
        await assertRedeemFails(api, at: origin, with: .failed)
        let result = try await api.redeem(origin: origin, code: fakeQRCode)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.user, "owner")
        XCTAssertTrue(result.token == "fake-session-token")
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, replies.count + 2)
    }

    @MainActor
    func testConfirmedQRLoginProbesAndRedeemsOverIsolatedURLSession() async throws {
        let origin = URL(string: "https://hestia.example:11443")!
        let oldOrigin = URL(string: "https://hestia.example:12443")!
        let payload = try XCTUnwrap(QRLoginPayload(rawValue: "hestia-login:\(origin.absoluteString)#\(fakeQRCode)"))
        MockQRLoginURLProtocol.install([
            .init(200, #"{"auth_contract":2,"features":["qr_login"],"qr_origin":"\#(origin.absoluteString)"}"#,
                  headers: ["Set-Cookie": "hestia_session=fake-cookie; Path=/; Secure"]),
            .init(401, #"{"error":{"code":"qr_code_invalid"}}"#),
        ], at: origin)
        defer { MockQRLoginURLProtocol.remove(at: origin) }
        let probeSession = Self.mockSession(for: HTTPSession.featuresProbe)
        let redeemSession = Self.mockSession(for: HTTPSession.qrRedeem)
        defer {
            probeSession.invalidateAndCancel()
            redeemSession.invalidateAndCancel()
        }
        let store = try testCredentialSessionStore(origin: oldOrigin, token: "fake-old-token")
        let transport = URLSessionTransport(configuration: .init(session: probeSession, httpBodyProcessingMode: .buffered))
        let api = APIClient(transport: transport, sessionStore: store)
        let redeem = QRLoginAPI(session: redeemSession)
        let app = AppState(api: api, sessionStore: store, redeemQRLogin: redeem.redeem)

        do {
            try await app.signIn(with: payload)
            XCTFail("Expected the mock redeem to fail")
        } catch {
            XCTAssertEqual(error as? QRLoginError, .invalidCode)
        }
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin), ["/api/auth/features", "/api/auth/qr-redeem"])
        XCTAssertEqual(store.currentSnapshot()?.origin, oldOrigin)
        XCTAssertNil(app.serverFeatures)
    }

    @MainActor
    func testNewRedeemFailuresPreserveSessionAndPermitLaterAttempts() async throws {
        let origin = URL(string: "https://hestia.example:15443")!
        let oldOrigin = URL(string: "https://hestia.example:16443")!
        let payload = try XCTUnwrap(QRLoginPayload(rawValue: "hestia-login:\(origin.absoluteString)#\(fakeQRCode)"))
        let errors: [(status: Int, code: String, expected: QRLoginError)] = [
            (400, "qr_invalid_request", .failed),
            (408, "request_timeout", .failed),
            (411, "length_required", .failed),
            (413, "request_too_large", .failed),
            (415, "unsupported_media_type", .failed),
            (503, "auth_bridge_incompatible", .originUnavailable),
        ]
        let features = MockQRLoginURLProtocol.Reply(
            200, #"{"auth_contract":2,"features":["qr_login"],"qr_origin":"\#(origin.absoluteString)"}"#
        )
        MockQRLoginURLProtocol.install(errors.flatMap { status, code, _ in [
            features, .init(status, #"{"error":{"code":"\#(code)"}}"#, headers: ["Retry-After": "60"]),
        ] }, at: origin)
        defer { MockQRLoginURLProtocol.remove(at: origin) }

        let probeSession = Self.mockSession(for: HTTPSession.featuresProbe)
        let redeemSession = Self.mockSession(for: HTTPSession.qrRedeem)
        defer {
            probeSession.invalidateAndCancel()
            redeemSession.invalidateAndCancel()
        }
        let store = try testCredentialSessionStore(origin: oldOrigin, token: "fake-old-token")
        let original = try XCTUnwrap(store.currentSnapshot())
        let originalOverride = store.backendURLStore.loadOverrideRecord()
        let transport = URLSessionTransport(configuration: .init(session: probeSession, httpBodyProcessingMode: .buffered))
        let api = APIClient(transport: transport, sessionStore: store)
        let redeem = QRLoginAPI(session: redeemSession)
        let app = AppState(api: api, sessionStore: store, redeemQRLogin: redeem.redeem)

        for (status, _, expected) in errors {
            do {
                try await app.signIn(with: payload)
                XCTFail("Expected QR redeem to fail with HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? QRLoginError, expected, "HTTP \(status)")
            }
            XCTAssertEqual(store.currentSnapshot(), original, "HTTP \(status)")
            XCTAssertEqual(store.backendURLStore.loadOverrideRecord(), originalOverride, "HTTP \(status)")
            XCTAssertNil(app.serverFeatures, "HTTP \(status)")
        }
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin),
                       errors.flatMap { _ in ["/api/auth/features", "/api/auth/qr-redeem"] })
    }

    func testRedeemHonorsRetryAfterSecondsAndHTTPDateWithoutResending() async throws {
        let origin = URL(string: "https://hestia.example:9443")!
        let otherOrigin = URL(string: "https://hestia.example:10443")!
        let body = #"{"error":{"code":"qr_rate_limited"}}"#
        MockQRLoginURLProtocol.install([
            .init(429, body, headers: ["Retry-After": "30"]),
            .init(429, body, headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:45 GMT"]),
            .init(429, body, headers: ["Retry-After": "Thursday, 01-Jan-70 00:01:00 GMT"]),
            .init(429, body, headers: ["Retry-After": "Thu Jan  1 00:01:15 1970"]),
            .success,
        ], at: origin)
        MockQRLoginURLProtocol.install([.success], at: otherOrigin)
        defer {
            MockQRLoginURLProtocol.remove(at: origin)
            MockQRLoginURLProtocol.remove(at: otherOrigin)
        }
        let clock = QRRetryTestClock()
        let session = Self.mockSession(for: HTTPSession.qrRedeem)
        defer { session.invalidateAndCancel() }
        let api = clock.makeAPI(session: session)

        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 30))
        clock.advance(by: 10)
        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 20))
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, 1)
        _ = try await api.redeem(origin: otherOrigin, code: fakeQRCode)

        clock.advance(by: 20)
        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 15))
        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 15))
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, 2)
        clock.advance(by: 15)
        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 15))
        clock.advance(by: 15)
        await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 15))
        clock.advance(by: 15)
        _ = try await api.redeem(origin: origin, code: fakeQRCode)
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, 5)
    }

    func testRedeemClampsOversizedRetryAfterToFifteenMinutes() async throws {
        let origin = URL(string: "https://hestia.example:13443")!
        let body = #"{"error":{"code":"qr_rate_limited"}}"#
        let headers = [
            String(UInt64.max),
            "18446744073709551616", // Valid decimal digits beyond UInt64.
            "1760000000", // Unix timestamp in seconds.
            "1760000000000", // Unix timestamp in milliseconds.
            "Fri, 31 Dec 9999 23:59:59 GMT",
        ]
        MockQRLoginURLProtocol.install(headers.flatMap { [
            .init(429, body, headers: ["Retry-After": $0]), .success,
        ] }, at: origin)
        defer { MockQRLoginURLProtocol.remove(at: origin) }
        let session = Self.mockSession(for: HTTPSession.qrRedeem)
        defer { session.invalidateAndCancel() }
        let clock = QRRetryTestClock()
        let api = clock.makeAPI(session: session)

        for index in headers.indices {
            await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 900))
            clock.advance(by: 899)
            await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: 1))
            XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, 2 * index + 1)
            clock.advance(by: 1)
            _ = try await api.redeem(origin: origin, code: fakeQRCode)
        }

        let oversized = QRLoginError.rateLimited(retryAfter: TimeInterval(UInt64.max))
        let generic = QRLoginError.rateLimited(retryAfter: nil)
        XCTAssertEqual(oversized.errorDescription, generic.errorDescription)
    }

    func testRedeemTreatsInvalidOrZeroRetryAfterAsNoCooldown() async throws {
        let origin = URL(string: "https://hestia.example:14443")!
        let body = #"{"error":{"code":"qr_rate_limited"}}"#
        let cases: [(header: String, delay: TimeInterval?)] = [
            ("Mon, 30 Feb 1970 00:00:30 GMT", nil),
            ("0", 0),
            ("-1", nil),
            ("soon", nil),
        ]
        let replies = cases.map { MockQRLoginURLProtocol.Reply(429, body, headers: ["Retry-After": $0.header]) }
        MockQRLoginURLProtocol.install(replies + [.success], at: origin)
        defer { MockQRLoginURLProtocol.remove(at: origin) }
        let session = Self.mockSession(for: HTTPSession.qrRedeem)
        defer { session.invalidateAndCancel() }
        let api = QRRetryTestClock().makeAPI(session: session)

        for fixture in cases {
            await assertRedeemFails(api, at: origin, with: .rateLimited(retryAfter: fixture.delay))
        }
        _ = try await api.redeem(origin: origin, code: fakeQRCode)
        XCTAssertEqual(MockQRLoginURLProtocol.requestedPaths(at: origin).count, cases.count + 1)
    }

    func testRedeemRejectsInsecureOrNonOriginURLBeforeSendingCode() async {
        let session = Self.mockSession(for: HTTPSession.qrRedeem)
        defer { session.invalidateAndCancel() }
        let api = QRLoginAPI(session: session)
        for raw in ["http://hestia.example", "https://owner@hestia.example", "https://hestia.example/path"] {
            await assertRedeemFails(api, at: URL(string: raw)!, with: .originMismatch)
        }
    }

    private func assertRedeemFails(
        _ api: QRLoginAPI, at origin: URL, with expected: QRLoginError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await api.redeem(origin: origin, code: fakeQRCode)
            XCTFail("Expected QR redeem to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? QRLoginError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("fake-redacted-value"), file: file, line: line)
        }
    }

    private static func mockSession(for production: URLSession) -> URLSession {
        let configuration = production.configuration
        configuration.protocolClasses = [MockQRLoginURLProtocol.self]
        return URLSession(configuration: configuration, delegate: production.delegate, delegateQueue: nil)
    }
}

private final class QRRetryTestClock: Sendable {
    private let elapsed = OSAllocatedUnfairLock(initialState: TimeInterval.zero)
    private let start = ContinuousClock.now

    func advance(by seconds: TimeInterval) {
        elapsed.withLock { $0 += seconds }
    }

    func makeAPI(session: URLSession) -> QRLoginAPI {
        QRLoginAPI(session: session, now: {
            Date(timeIntervalSince1970: self.elapsed.withLock { $0 })
        }, monotonicNow: {
            self.start.advanced(by: .seconds(self.elapsed.withLock { $0 }))
        })
    }
}

private final class QRChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class MockQRLoginURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: String
        let headers: [String: String]

        init(_ status: Int, _ body: String, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers.merging(["Content-Type": "application/json"]) { original, _ in original }
        }

        static let success = Reply(200, #"{"ok":true,"user":"owner","token":"fake-session-token"}"#)
    }

    private struct Fixture {
        var replies: [Reply]
        var requestedPaths: [String] = []
    }

    private static let fixtures = OSAllocatedUnfairLock(initialState: [Int: Fixture]())

    static func install(_ replies: [Reply], at origin: URL) {
        fixtures.withLock { $0[origin.port ?? 443] = Fixture(replies: replies) }
    }

    static func requestedPaths(at origin: URL) -> [String] {
        fixtures.withLock { $0[origin.port ?? 443]?.requestedPaths ?? [] }
    }

    static func remove(at origin: URL) {
        fixtures.withLock { $0[origin.port ?? 443] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "hestia.example")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if url.path == "/api/auth/qr-redeem" {
                try assertRedeemRequest(url: url)
            } else {
                XCTAssertEqual(url.path, "/api/auth/features")
                XCTAssertEqual(request.httpMethod, "GET")
            }

            let reply = try XCTUnwrap(Self.fixtures.withLock { fixtures -> Reply? in
                let key = url.port ?? 443
                guard var fixture = fixtures[key], !fixture.replies.isEmpty else { return nil }
                fixture.requestedPaths.append(url.path)
                let reply = fixture.replies.removeFirst()
                fixtures[key] = fixture
                return reply
            })
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil,
                                                        headerFields: reply.headers))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func assertRedeemRequest(url: URL) throws {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body: Any
        if let data = request.httpBody {
            body = try JSONSerialization.jsonObject(with: data)
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            body = try JSONSerialization.jsonObject(with: stream)
        }
        let values = try XCTUnwrap(body as? [String: String])
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values["code"] == fakeQRCode)
        var origin = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        origin.path = ""
        XCTAssertEqual(values["origin"], origin.string)
    }

    override func stopLoading() {}
}
