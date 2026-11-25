import XCTest
@testable import Vesta

@MainActor
extension QRLoginTests {
    @objc func testZeroRequestsBeforeConfirmation() async throws {
        let fixture = QRConfirmationFixture()
        await fixture.app.bootstrap()
        XCTAssertEqual(fixture.app.phase, .unconfigured)
        XCTAssertTrue(fixture.app.canScanQRLogin)

        await fixture.scan()

        let pendingScan = try XCTUnwrap(fixture.presentation.pendingScan)
        XCTAssertEqual(pendingScan.payload.origin, fixture.origin)
        XCTAssertNil(fixture.app.savedBackendOverride)
        let probesBeforeConfirmation = await fixture.api.probeOrigins
        let callsBeforeConfirmation = await fixture.api.calls
        let redeemsBeforeConfirmation = await fixture.redeemer.origins
        XCTAssertTrue(probesBeforeConfirmation.isEmpty)
        XCTAssertTrue(callsBeforeConfirmation.isEmpty)
        XCTAssertTrue(redeemsBeforeConfirmation.isEmpty)

        await fixture.enableQRSignIn()
        await fixture.presentation.confirm(pendingScan, locale: .current, signIn: fixture.app.signIn(with:))
        XCTAssertNil(fixture.presentation.pendingScan)
        let probesAfterConfirmation = await fixture.api.probeOrigins
        let redeemsAfterConfirmation = await fixture.redeemer.origins
        XCTAssertEqual(probesAfterConfirmation, [fixture.origin])
        XCTAssertEqual(redeemsAfterConfirmation, [fixture.origin])
        XCTAssertEqual(fixture.app.savedBackendOverride, fixture.origin)
    }

    @objc func testQRConfirmationForDifferentSavedOriginCanBeCancelled() async throws {
        let savedOrigin = try XCTUnwrap(URL(string: "https://hestia.example:8443"))
        let fixture = QRConfirmationFixture(savedOrigin: savedOrigin)

        await fixture.scan()
        let pendingScan = try XCTUnwrap(fixture.presentation.pendingScan)
        XCTAssertEqual(pendingScan.payload.origin, fixture.origin)
        fixture.presentation.cancelConfirmation()
        XCTAssertNil(fixture.presentation.pendingScan)
        await fixture.presentation.confirm(pendingScan, locale: .current, signIn: fixture.app.signIn(with:))

        let probes = await fixture.api.probeOrigins
        let redeems = await fixture.redeemer.origins
        XCTAssertTrue(probes.isEmpty)
        XCTAssertTrue(redeems.isEmpty)
        XCTAssertEqual(fixture.app.savedBackendOverride, savedOrigin)
    }

    @objc func testQRSavedMatchingOriginSignsInWithoutConfirmation() async throws {
        let savedOrigin = try XCTUnwrap(URL(string: "https://hestia.example:443"))
        let fixture = QRConfirmationFixture(savedOrigin: savedOrigin)
        await fixture.enableQRSignIn()

        await fixture.scan()

        XCTAssertNil(fixture.presentation.pendingScan)
        let probes = await fixture.api.probeOrigins
        let redeems = await fixture.redeemer.origins
        XCTAssertEqual(probes, [fixture.origin])
        XCTAssertEqual(redeems, [fixture.origin])
    }

    @objc func testQRInvalidScanDoesNotPromptOrStartSignIn() async {
        let fixture = QRConfirmationFixture()

        await fixture.presentation.receiveScan("not a sign-in QR payload", savedOverride: nil, locale: .current,
                                               signIn: fixture.app.signIn(with:))

        XCTAssertNil(fixture.presentation.pendingScan)
        XCTAssertNotNil(fixture.presentation.message)
        let probes = await fixture.api.probeOrigins
        let redeems = await fixture.redeemer.origins
        XCTAssertTrue(probes.isEmpty)
        XCTAssertTrue(redeems.isEmpty)
    }

    @objc func testQRRoutingOnSavedOriginRequiresAdvertisedSupport() async throws {
        let origin = try XCTUnwrap(URL(string: "https://hestia.example"))
        let legacy = QRConfirmationFixture(savedOrigin: origin)
        await legacy.api.setCapabilitiesError(.unauthorized)
        await legacy.app.bootstrap()
        XCTAssertEqual(legacy.app.phase, .needsAuth)
        XCTAssertFalse(legacy.app.canScanQRLogin)

        let modern = QRConfirmationFixture(savedOrigin: origin)
        await modern.enableQRSignIn()
        await modern.api.setCapabilitiesError(.unauthorized)
        await modern.app.bootstrap()
        XCTAssertEqual(modern.app.phase, .needsAuth)
        XCTAssertTrue(modern.app.canScanQRLogin)
    }
}

private actor QRConfirmationRedeemer {
    private(set) var origins: [URL] = []

    func redeem(origin: URL, code: String) async throws -> QRLoginResponse {
        origins.append(origin)
        return QRLoginResponse(ok: true, user: "fixture-user", token: "fixture-token")
    }
}

@MainActor
private struct QRConfirmationFixture {
    let origin = URL(string: "https://hestia.example")!
    let api = MockHestiaAPI()
    let redeemer = QRConfirmationRedeemer()
    let presentation = QRLoginPresentation()
    let app: AppState

    init(savedOrigin: URL? = nil) {
        let defaults = UserDefaults(suiteName: "VestaTests.QRConfirmation.\(UUID())")!
        let urls = BackendURLStore(userDefaults: defaults)
        if let savedOrigin { urls.saveOverride(savedOrigin) }
        let session = CredentialSessionStore(backendURLStore: urls, keychain: TestSessionKeychain())
        app = AppState(api: api, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
                       sessionStore: session, redeemQRLogin: redeemer.redeem,
                       events: { _ in AsyncStream { $0.finish() } })
    }

    func enableQRSignIn() async {
        await api.setFeatures(ServerFeatures(authContract: 2, features: [.qrLogin, .capabilities],
                                             qrOrigin: origin, isLegacy: false))
        await api.setCapabilities(Capabilities(user: "fixture-user"))
    }

    func scan() async {
        // Simulate the scanner callback with 14 zero bytes encoded as base64url.
        let code = String(repeating: "A", count: 19)
        await presentation.receiveScan("hestia-login:\(origin.absoluteString)#\(code)",
                                       savedOverride: app.savedBackendOverride, locale: .current,
                                       signIn: app.signIn(with:))
    }
}
