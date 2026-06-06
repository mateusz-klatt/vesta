import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

final class TokenStoreTests: XCTestCase {
    override func tearDown() { TokenStore.clear(); super.tearDown() }

    func testRoundTrip() {
        TokenStore.clear()
        XCTAssertNil(TokenStore.load())
        TokenStore.save("abc123")
        XCTAssertEqual(TokenStore.load(), "abc123")
        TokenStore.save("def456")          // overwrite
        XCTAssertEqual(TokenStore.load(), "def456")
        TokenStore.clear()
        XCTAssertNil(TokenStore.load())
    }
}

final class BearerAuthMiddlewareTests: XCTestCase {
    private func request() -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "host", path: "/x")
    }

    // `next` is @Sendable, so echo the request's auth header into the response
    // instead of capturing it, then assert on the response.
    func testAddsAuthorizationWhenTokenPresent() async throws {
        let middleware = BearerAuthMiddleware(token: { "tok" })
        let (response, _) = try await middleware.intercept(
            request(), body: nil, baseURL: URL(string: "https://host")!, operationID: "op"
        ) { req, _, _ in
            var resp = HTTPResponse(status: .ok)
            if let auth = req.headerFields[.authorization] { resp.headerFields[.authorization] = auth }
            return (resp, nil)
        }
        XCTAssertEqual(response.headerFields[.authorization], "Bearer tok")
    }

    func testNoHeaderWhenTokenAbsent() async throws {
        let middleware = BearerAuthMiddleware(token: { nil })
        let (response, _) = try await middleware.intercept(
            request(), body: nil, baseURL: URL(string: "https://host")!, operationID: "op"
        ) { req, _, _ in
            var resp = HTTPResponse(status: .ok)
            if let auth = req.headerFields[.authorization] { resp.headerFields[.authorization] = auth }
            return (resp, nil)
        }
        XCTAssertNil(response.headerFields[.authorization])
    }
}

final class BackendURLStoreOverrideTests: XCTestCase {
    private func freshStore() -> BackendURLStore {
        BackendURLStore(userDefaults: UserDefaults(suiteName: "vesta.test.\(UUID().uuidString)")!)
    }

    func testOverrideLifecycle() {
        let store = freshStore()
        XCTAssertFalse(store.hasOverride())
        let url = BackendURLStore.canonicalize("https://my.example")!
        store.saveOverride(url)
        XCTAssertTrue(store.hasOverride())
        XCTAssertEqual(store.currentEffectiveURL(), url)
        store.clearOverride()
        XCTAssertFalse(store.hasOverride())
    }

    func testBundledDefaultAlwaysValid() {
        let store = freshStore()
        XCTAssertFalse(store.bundledBaseURL().absoluteString.isEmpty)
        // With no override, the effective URL is the bundled default.
        XCTAssertEqual(store.currentEffectiveURL(), store.bundledBaseURL())
    }

    func testCorruptOverrideIsIgnored() {
        let defaults = UserDefaults(suiteName: "vesta.test.\(UUID().uuidString)")!
        defaults.set("not a url", forKey: BackendURLStore.userDefaultsKey)
        let store = BackendURLStore(userDefaults: defaults)
        XCTAssertFalse(store.hasOverride())   // garbage cleared on load
    }
}
