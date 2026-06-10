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

    func testTransportErrorIsWrapped() async {
        let api = APIClient(transport: StubTransport { _ in throw URLError(.cannotFindHost) })
        await XCTAssertThrowsErrorEqual(try await api.whoami(), APIError.serverNotFound)
    }

    func testLoginStoresToken() async throws {
        TokenStore.clear()
        let api = APIClient(transport: StubTransport { _ in (200, json(#"{"ok":true,"token":"tok","user":"u"}"#)) })
        let success = try await api.login(user: "u", password: "p")
        XCTAssertEqual(success.token, "tok")
        XCTAssertEqual(TokenStore.load(), "tok")
        TokenStore.clear()
    }

    func testLoginBadCredentials() async {
        let api = APIClient(transport: StubTransport { _ in (401, json(#"{"ok":false,"error":"bad"}"#)) })
        await XCTAssertThrowsErrorEqual(try await api.login(user: "u", password: "x"), APIError.unauthorized)
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
        let api = APIClient(transport: StubTransport { _ in (200, nil) })
        await api.logout()   // must not throw
    }
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
