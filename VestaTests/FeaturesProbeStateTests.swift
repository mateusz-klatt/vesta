import XCTest
@testable import Vesta

@MainActor
final class FeaturesProbeStateTests: XCTestCase {
    private let modernFeatures = ServerFeatures(
        authContract: 2, features: [.capabilities], qrOrigin: nil, isLegacy: false
    )
    private let expandedFeatures = ServerFeatures(
        authContract: 2, features: [.capabilities, .calendarInstances, .qrLogin],
        qrOrigin: URL(string: "https://hestia.example")!, isLegacy: false
    )

    private func makeApp(_ mock: MockHestiaAPI) -> AppState {
        AppState(api: mock, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
                 events: { AsyncStream { $0.finish() } })
    }

    private func withSavedOrigin(_ body: (URL) async throws -> Void) async rethrows {
        let store = BackendURLStore.shared
        let previous = store.hasOverride() ? store.currentEffectiveURL() : nil
        let origin = URL(string: "https://hestia.example")!
        store.saveOverride(origin)
        defer {
            if let previous { store.saveOverride(previous) } else { store.clearOverride() }
        }
        try await body(origin)
    }

    func testColdLaunchSavedOrigin401PublishesFeaturesWithNilCapabilities() async throws {
        try await withSavedOrigin { origin in
            let mock = MockHestiaAPI()
            await mock.setFeatures(expandedFeatures)
            await mock.setCapabilitiesError(.unauthorized)
            let app = makeApp(mock)

            await app.bootstrap()

            XCTAssertEqual(app.phase, .needsAuth)
            XCTAssertEqual(app.serverFeatures, expandedFeatures)
            XCTAssertNil(app.capabilities)
            XCTAssertTrue(app.rooms.isEmpty)
            let probes = await mock.probeOrigins
            let requests = await mock.capabilityRequests
            let calls = await mock.calls
            XCTAssertEqual(probes, [origin])
            XCTAssertEqual(requests, [.init(origin: origin, features: expandedFeatures)])
            XCTAssertEqual(calls, [.capabilities])
        }
    }

    func testSignedOutForegroundUsesProbeOnlyWithZeroAuthenticatedRequests() async throws {
        try await withSavedOrigin { origin in
            let mock = MockHestiaAPI()
            await mock.setFeatures(modernFeatures)
            await mock.setCapabilities(Capabilities(user: "viewer"))
            let app = makeApp(mock)
            await app.connect()
            await app.signOut()
            let callsBeforeForeground = await mock.calls
            await mock.setFeatures(expandedFeatures)

            app.enterBackground()
            app.enterForeground()
            try await waitUntil("the signed-out foreground feature publication") {
                app.serverFeatures == expandedFeatures
            }

            XCTAssertEqual(app.phase, .needsAuth)
            XCTAssertNil(app.capabilities)
            let probes = await mock.probeOrigins
            let calls = await mock.calls
            XCTAssertEqual(probes, [origin, origin])
            XCTAssertEqual(calls, callsBeforeForeground)
        }
    }

    func testFeaturesWaitForCapabilitiesBeforePublishingTheNewSnapshot() async throws {
        let mock = MockHestiaAPI()
        await mock.setFeatures(modernFeatures)
        let original = Capabilities(user: "viewer")
        let updated = Capabilities(user: "viewer", installation: [.calendarView])
        await mock.setCapabilities(original)
        let app = makeApp(mock)
        await app.connect()
        XCTAssertEqual(app.serverFeatures, modernFeatures)
        XCTAssertEqual(app.capabilities, original)

        await mock.setFeatures(expandedFeatures)
        await mock.setCapabilities(updated)
        await mock.setHoldCapabilities()
        defer { Task { await mock.releaseCapabilities() } }
        let refresh = Task { await app.refresh() }
        try await waitUntil("the held capabilities response") { await mock.isCapabilitiesHeld }
        XCTAssertEqual(app.serverFeatures, modernFeatures)
        XCTAssertEqual(app.capabilities, original)
        XCTAssertNil(app.calendarAPI)

        await mock.releaseCapabilities()
        await refresh.value
        XCTAssertEqual(app.serverFeatures, expandedFeatures)
        XCTAssertEqual(app.capabilities, updated)
        XCTAssertEqual(app.whoami?.user, updated.user)
        XCTAssertNil(app.whoami?.role)
        XCTAssertNotNil(app.calendarAPI)
    }

    func testForbiddenCapabilityRefreshPublishesFeatureRemoval() async {
        let mock = MockHestiaAPI()
        await mock.setFeatures(expandedFeatures)
        await mock.setCapabilities(Capabilities(user: "viewer", installation: [.calendarView]))
        let app = makeApp(mock)
        await app.connect()
        XCTAssertEqual(app.serverFeatures, expandedFeatures)
        XCTAssertNotNil(app.calendarAPI)

        await mock.setFeatures(modernFeatures)
        await mock.setCapabilitiesError(.forbidden)
        await app.refresh()

        XCTAssertEqual(app.serverFeatures, modernFeatures)
        XCTAssertNil(app.capabilities)
        XCTAssertNil(app.calendarAPI)
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.notice, .forbidden)
        let requests = await mock.capabilityRequests
        XCTAssertEqual(requests.map(\.features), [expandedFeatures, modernFeatures])
    }

    func testProbeTransportErrorFailsInitialConnectAndPreservesReadyAuthorizationDuringPull() async {
        let mock = MockHestiaAPI()
        let app = makeApp(mock)
        await mock.setProbeError(URLError(.timedOut))

        await app.connect()
        XCTAssertEqual(app.phase, .failed(.timedOut))
        XCTAssertNil(app.serverFeatures)
        XCTAssertNil(app.capabilities)
        let failedConnectCalls = await mock.calls
        XCTAssertTrue(failedConnectCalls.isEmpty)

        let grant = Capabilities(user: "viewer")
        await mock.setFeatures(modernFeatures)
        await mock.setCapabilities(grant)
        await app.connect()
        await mock.setProbeError(URLError(.timedOut))

        await app.refresh()
        XCTAssertEqual(app.phase, .ready)
        XCTAssertNil(app.notice)
        XCTAssertEqual(app.serverFeatures, modernFeatures)
        XCTAssertEqual(app.capabilities, grant)
        let refreshCalls = await mock.calls
        XCTAssertEqual(refreshCalls, [.capabilities])
    }

    func testLateProbeResponseIsDiscardedAfterNewerRefreshOnSameOrigin() async throws {
        let mock = MockHestiaAPI()
        await mock.setFeatures(modernFeatures)
        let grant = Capabilities(user: "viewer", installation: [.calendarView])
        await mock.setCapabilities(grant)
        let app = makeApp(mock)
        await app.connect()

        await mock.setFeatures(expandedFeatures)
        await mock.setHoldProbe()
        defer { Task { await mock.releaseProbe() } }
        let staleRefresh = Task { await app.refresh() }
        try await waitUntil("the older refresh's held probe") { await mock.isProbeHeld }

        await mock.setFeatures(.legacy)
        await app.refresh()
        await mock.releaseProbe()
        await staleRefresh.value

        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.serverFeatures, .legacy)
        XCTAssertEqual(app.capabilities, grant)
        XCTAssertNil(app.calendarAPI)
        let requests = await mock.capabilityRequests
        XCTAssertEqual(requests.map(\.features), [modernFeatures, .legacy])
    }

    func testLateProbeResponseIsDiscardedAfterServerSwitch() async throws {
        try await withSavedOrigin { originalOrigin in
            let mock = MockHestiaAPI()
            await mock.setFeatures(modernFeatures)
            await mock.setCapabilities(Capabilities(user: "viewer"))
            let app = makeApp(mock)
            await app.connect()

            await mock.setFeatures(expandedFeatures)
            await mock.setHoldProbe()
            defer { Task { await mock.releaseProbe() } }
            let refresh = Task { await app.refresh() }
            try await waitUntil("the old origin's held probe") { await mock.isProbeHeld }

            let newOrigin = URL(string: "https://hestia.example:8443")!
            let newCapabilities = Capabilities(user: "viewer", installation: [.calendarView])
            await mock.setFeatures(.legacy)
            await mock.setCapabilities(newCapabilities)
            XCTAssertTrue(app.saveAndConnect(newOrigin.absoluteString))
            XCTAssertNil(app.serverFeatures)
            try await waitUntil("the new origin's capabilities") { app.phase == .ready }

            await mock.releaseProbe()
            await refresh.value
            XCTAssertEqual(app.serverFeatures, .legacy)
            XCTAssertEqual(app.capabilities, newCapabilities)
            XCTAssertNil(app.calendarAPI)
            let probes = await mock.probeOrigins
            let requests = await mock.capabilityRequests
            XCTAssertEqual(probes, [originalOrigin, originalOrigin, newOrigin])
            XCTAssertEqual(requests, [
                .init(origin: originalOrigin, features: modernFeatures),
                .init(origin: newOrigin, features: .legacy),
            ])
        }
    }

    func testLateProbeResponseIsDiscardedAfterSignOut() async throws {
        let mock = MockHestiaAPI()
        await mock.setFeatures(modernFeatures)
        await mock.setCapabilities(Capabilities(user: "viewer"))
        let app = makeApp(mock)
        await app.connect()

        await mock.setFeatures(expandedFeatures)
        await mock.setHoldProbe()
        defer { Task { await mock.releaseProbe() } }
        let refresh = Task { await app.refresh() }
        try await waitUntil("the old session's held probe") { await mock.isProbeHeld }

        await app.signOut()
        await mock.releaseProbe()
        await refresh.value

        XCTAssertEqual(app.phase, .needsAuth)
        XCTAssertEqual(app.serverFeatures, modernFeatures)
        XCTAssertNil(app.capabilities)
        let calls = await mock.calls
        XCTAssertEqual(calls, [.capabilities])
    }
}
