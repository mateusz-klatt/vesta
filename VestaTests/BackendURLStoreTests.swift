import XCTest
@testable import Vesta

final class BackendURLStoreTests: XCTestCase {

    func testAcceptsHTTPSPublicOriginAndNormalises() {
        let url = BackendURLStore.canonicalize("  HTTPS://Hestia.Example  ")
        XCTAssertEqual(url?.absoluteString, "https://hestia.example")
    }

    func testRejectsPublicHTTP() {
        XCTAssertNil(BackendURLStore.canonicalize("http://hestia.example"))
    }

    func testAcceptsHTTPForLANHosts() {
        XCTAssertNotNil(BackendURLStore.canonicalize("http://192.168.1.50:8080"))
        XCTAssertNotNil(BackendURLStore.canonicalize("http://hestia.local"))
        XCTAssertNotNil(BackendURLStore.canonicalize("http://localhost:8080"))
        XCTAssertNotNil(BackendURLStore.canonicalize("http://10.0.0.4"))
        XCTAssertNotNil(BackendURLStore.canonicalize("http://172.16.5.5"))
    }

    func testRejectsHTTPForNonLANPrivateLookalike() {
        // 172.32.x is outside the 172.16–31 private range.
        XCTAssertNil(BackendURLStore.canonicalize("http://172.32.0.1"))
    }

    func testRejectsPathQueryFragmentUserinfo() {
        XCTAssertNil(BackendURLStore.canonicalize("https://hestia.example/api"))
        XCTAssertNil(BackendURLStore.canonicalize("https://hestia.example?x=1"))
        XCTAssertNil(BackendURLStore.canonicalize("https://hestia.example#frag"))
        XCTAssertNil(BackendURLStore.canonicalize("https://user:pass@hestia.example"))
    }

    func testStripsLoneTrailingSlash() {
        let url = BackendURLStore.canonicalize("https://hestia.example/")
        XCTAssertEqual(url?.absoluteString, "https://hestia.example")
    }

    func testRejectsGarbageAndEmpty() {
        XCTAssertNil(BackendURLStore.canonicalize(""))
        XCTAssertNil(BackendURLStore.canonicalize("   "))
        XCTAssertNil(BackendURLStore.canonicalize("ftp://hestia.example"))
        XCTAssertNil(BackendURLStore.canonicalize("not a url"))
    }
}
