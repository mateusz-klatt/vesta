import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

/// A canned OpenAPI transport: the handler maps a request to (status, json body)
/// or throws, so we can exercise APIClient without the network.
struct StubTransport: ClientTransport {
    let handler: @Sendable (HTTPRequest) throws -> (Int, Data?)

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let (status, data) = try handler(request)
        var response = HTTPResponse(status: .init(code: status))
        guard let data else { return (response, nil) }
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody([UInt8](data)))
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

@MainActor
func testCredentialSessionStore(origin: URL = AppConfig.serverURL, token: String) throws -> CredentialSessionStore {
    let urls = BackendURLStore(userDefaults: UserDefaults(suiteName: "vesta.test.\(UUID())")!)
    let store = CredentialSessionStore(backendURLStore: urls, keychain: TestSessionKeychain())
    try store.commitAuthoritative(origin: origin, actor: "u", token: token)
    return store
}

/// Holds one operation's response until released; every other operation answers at once.
private final class HeldTransport: ClientTransport, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        let operation: String
        let origin: URL
        let authorization: String?
    }

    private let held: String
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private var recorded: [Call] = []
    var isHolding: Bool { lock.withLock { gate != nil } }
    var calls: [Call] { lock.withLock { recorded } }

    init(holding operationID: String = Operations.Login.id) { held = operationID }

    func release() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            defer { gate = nil }
            return gate
        }
        pending?.resume()
    }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        lock.withLock {
            recorded.append(.init(operation: operationID, origin: baseURL, authorization: request.headerFields[.authorization]))
        }
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        let reply = switch operationID {
        case Operations.Login.id: #"{"ok":true,"token":"new-token","user":"u"}"#
        case Operations.Whoami.id: #"{"user":"u","role":"admin"}"#
        default: #"{"ok":true}"#
        }
        guard operationID == held else { return (response, HTTPBody(reply)) }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if released { return true }
                gate = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return (response, HTTPBody(reply))
    }
}

/// Polls `condition` with a deadline, so a request that never arrives fails the
/// test instead of hanging the suite.
func waitUntil(isolation: isolated (any Actor)? = #isolation, _ what: String, timeout: Duration = .seconds(5),
               _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private let transportOrigin = URL(string: "https://hestia.example")!
private let otherTransportOrigin = URL(string: "https://hestia.example:8443")!

final class APIClientTests: XCTestCase {

    func testWhoamiDecodes() async throws {
        let api = APIClient(transport: StubTransport { _ in (200, json(#"{"user":"u","role":"admin"}"#)) })
        let who = try await api.whoami()
        XCTAssertEqual(who.user, "u")
        XCTAssertEqual(who.role, "admin")
    }

    func testWhoamiUnauthorizedMapped() async {
        let api = APIClient(transport: StubTransport { _ in (401, nil) })
        await XCTAssertThrowsErrorEqual(try await api.whoami(), APIError.unauthorized)
    }

    func testMapStatusSeparates401From403() async {
        let statuses: [(Int, APIError)] = [(401, .unauthorized), (403, .forbidden)]
        let origin = URL(string: "https://hestia.example")!
        for (status, expected) in statuses {
            let api = APIClient(transport: StubTransport { _ in (status, nil) })
            await XCTAssertThrowsErrorEqual(try await api.capabilities(on: origin, features: .legacy), expected)
            await XCTAssertThrowsErrorEqual(try await api.discovery(), expected)
            await XCTAssertThrowsErrorEqual(try await api.setSwitch(node: 4, on: true), expected)
            await XCTAssertThrowsErrorEqual(try await api.scene(.lightsOff), expected)
            await XCTAssertThrowsErrorEqual(try await api.sendIR(file: "k.ir", button: "off"), expected)
        }
    }

    func testTransportErrorIsWrapped() async {
        let api = APIClient(transport: StubTransport { _ in throw URLError(.cannotFindHost) })
        await XCTAssertThrowsErrorEqual(try await api.whoami(), APIError.serverNotFound)
    }

    @MainActor
    func testLoginReturnsTokenWithoutPublishingOrSendingPreviousBearer() async throws {
        let store = try testCredentialSessionStore(origin: transportOrigin, token: "previous-token")
        let previous = store.currentSnapshot()
        let transport = HeldTransport()
        transport.release()
        let api = APIClient(transport: transport, sessionStore: store)

        let success = try await api.login(user: "u", password: "p", on: transportOrigin)

        XCTAssertEqual(success.token, "new-token")
        XCTAssertEqual(success.user, "u")
        XCTAssertEqual(store.currentSnapshot(), previous)
        XCTAssertEqual(transport.calls, [.init(operation: Operations.Login.id, origin: transportOrigin, authorization: nil)])
    }

    func testRemoteLogoutDuringLoginDoesNotChangeTheResult() async throws {
        let transport = HeldTransport()
        let api = APIClient(transport: transport)

        let login = Task { try await api.login(user: "u", password: "p", on: transportOrigin) }
        defer { transport.release() }
        try await waitUntil("the held login") { transport.isHolding }
        await api.remoteLogout(token: "previous-token", origin: otherTransportOrigin)
        transport.release()

        let success = try await login.value
        XCTAssertEqual(success.token, "new-token")
        XCTAssertEqual(transport.calls, [
            .init(operation: Operations.Login.id, origin: transportOrigin, authorization: nil),
            .init(operation: Operations.Logout.id, origin: otherTransportOrigin, authorization: "Bearer previous-token"),
        ])
    }

    @MainActor
    func testLoginAfterRemoteLogoutLeavesPublishedSessionUntouched() async throws {
        let transport = HeldTransport()
        transport.release()
        let store = try testCredentialSessionStore(origin: transportOrigin, token: "previous-token")
        let previous = store.currentSnapshot()
        let api = APIClient(transport: transport, sessionStore: store)

        await api.remoteLogout(token: "detached-token", origin: otherTransportOrigin)
        let success = try await api.login(user: "u", password: "p", on: transportOrigin)
        XCTAssertEqual(success.token, "new-token")
        XCTAssertEqual(store.currentSnapshot(), previous)
    }

    @MainActor
    func testSlowRemoteLogoutKeepsAConcurrentlyPublishedSession() async throws {
        let transport = HeldTransport(holding: Operations.Logout.id)
        let store = try testCredentialSessionStore(origin: transportOrigin, token: "previous-token")
        let api = APIClient(transport: transport, sessionStore: store)

        let logout = Task { await api.remoteLogout(token: "previous-token", origin: transportOrigin) }
        defer { transport.release() }
        try await waitUntil("the held logout") { transport.isHolding }
        let success = try await api.login(user: "u", password: "p", on: otherTransportOrigin)
        let published = try store.commitAuthoritative(origin: otherTransportOrigin, actor: success.user, token: XCTUnwrap(success.token))
        transport.release()
        await logout.value

        XCTAssertEqual(store.currentSnapshot(), published)
    }

    func testLoginBadCredentials() async {
        let api = APIClient(transport: StubTransport { _ in (401, json(#"{"ok":false,"error":"bad"}"#)) })
        await XCTAssertThrowsErrorEqual(
            try await api.login(user: "u", password: "x", on: transportOrigin), APIError.unauthorized
        )
    }

    func testControlSucceeds() async throws {
        let api = APIClient(transport: StubTransport { _ in (200, json(#"{"ok":true,"sent":"7e00"}"#)) })
        try await api.setSwitch(node: 4, on: true, endpoint: nil)
        try await api.setThermostat(node: 9, celsius: 22)
    }

    func testControlBadRequestMapped() async {
        let api = APIClient(transport: StubTransport { _ in (400, json(#"{"ok":false,"error":"nope"}"#)) })
        await XCTAssertThrowsErrorEqual(try await api.setCover(node: 5, value: 50), APIError.http(400))
    }

    func testSceneSucceeds() async throws {
        let api = APIClient(transport: StubTransport { _ in (200, json(#"{"ok":true,"sent":5,"total":5}"#)) })
        try await api.scene(.lightsOff)
    }

    func testSceneBadRequestMapped() async {
        let api = APIClient(transport: StubTransport { _ in (400, json(#"{"ok":false,"error":"unknown scene"}"#)) })
        await XCTAssertThrowsErrorEqual(try await api.scene(.blindsUp), APIError.http(400))
    }

    func testIRUnavailableMapped() async {
        let api = APIClient(transport: StubTransport { _ in (503, json(#"{"ok":false,"error":"busy"}"#)) })
        await XCTAssertThrowsErrorEqual(try await api.sendIR(file: "k.ir", button: "off"), APIError.http(503))
    }

    func testLogoutNeverThrows() async {
        let api = APIClient(transport: StubTransport { _ in throw URLError(.notConnectedToInternet) })
        await api.remoteLogout(token: "detached-token", origin: transportOrigin)
    }

    @MainActor
    func testImmutableBoundSessionAndSSESnapshotIgnoreMutatedDefaults() async throws {
        let urls = BackendURLStore(userDefaults: UserDefaults(suiteName: "vesta.test.\(UUID())")!)
        let store = CredentialSessionStore(backendURLStore: urls, keychain: TestSessionKeychain())
        let prior = try store.commitAuthoritative(origin: transportOrigin, actor: "u", token: "previous-token")
        let transport = HeldTransport(holding: Operations.Whoami.id)
        let api = APIClient(transport: transport, sessionStore: store)

        // Change the derived URL while the authoritative session still points to the old origin.
        urls.saveOverride(otherTransportOrigin)
        let events = SSESessionSnapshot(origin: prior.origin, session: store.currentSnapshot())
        let mismatched = SSESessionSnapshot(origin: otherTransportOrigin, session: prior)
        XCTAssertNil(mismatched.token)
        let first = Task { try await api.whoami() }
        defer { transport.release() }
        try await waitUntil("the old session request") { transport.isHolding }

        _ = try store.commitAuthoritative(origin: otherTransportOrigin, actor: "u2", token: "new-token")
        let configuration = HTTPSession.configuration
        configuration.protocolClasses = [SnapshotEventURLProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        var received: [EventStream.Event] = []
        for await event in EventStream.changes(snapshot: events, session: network) {
            received.append(event)
        }
        XCTAssertEqual(received, [.connected])

        transport.release()
        _ = try await first.value
        _ = try await api.whoami()
        _ = try await api.capabilities(on: transportOrigin, features: .legacy)
        XCTAssertEqual(transport.calls, [
            .init(operation: Operations.Whoami.id, origin: transportOrigin, authorization: "Bearer previous-token"),
            .init(operation: Operations.Whoami.id, origin: otherTransportOrigin, authorization: "Bearer new-token"),
            .init(operation: Operations.Whoami.id, origin: transportOrigin, authorization: nil),
        ])
    }
}

private final class SnapshotEventURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.url, transportOrigin.appendingPathComponent("api/events"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer previous-token")
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Assert an async expression throws a specific `APIError`.
func XCTAssertThrowsErrorEqual<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: APIError,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected to throw \(expected)", file: file, line: line)
    } catch let error as APIError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("threw \(error), expected \(expected)", file: file, line: line)
    }
}
