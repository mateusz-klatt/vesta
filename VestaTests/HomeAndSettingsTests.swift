import XCTest
@testable import Vesta

@MainActor
final class HomeAndSettingsTests: XCTestCase {
    func testPairingSheetsDismissWhenReceiptsWithdrawn() async {
        let api = MockHestiaAPI()
        let app = AppState(api: api)
        let receiptGrant = Capabilities(delegatedReceipts: .init(permissions: [.budgetReceiptsAdd], canUse: true))
        await api.setCapabilities(receiptGrant)
        await app.connect()

        var homePairing = ReceiptPairingPresentation()
        var settingsPairing = ReceiptPairingPresentation()
        XCTAssertNotNil(app.receiptsAPI)
        homePairing.present(in: app)
        settingsPairing.present(in: app)
        XCTAssertTrue(homePairing.isPresented(accessGeneration: app.receiptAccessGeneration))
        XCTAssertTrue(settingsPairing.isPresented(accessGeneration: app.receiptAccessGeneration))

        await api.setCapabilities(.init())
        await app.refresh()

        XCTAssertEqual(app.phase, .ready)
        XCTAssertNil(app.receiptsAPI)
        XCTAssertFalse(homePairing.isPresented(accessGeneration: app.receiptAccessGeneration))
        XCTAssertFalse(settingsPairing.isPresented(accessGeneration: app.receiptAccessGeneration))

        await api.setCapabilities(receiptGrant)
        await app.refresh()
        XCTAssertNotNil(app.receiptsAPI)
        XCTAssertFalse(homePairing.isPresented(accessGeneration: app.receiptAccessGeneration))
        XCTAssertFalse(settingsPairing.isPresented(accessGeneration: app.receiptAccessGeneration))

        homePairing.present(in: app)
        settingsPairing.present(in: app)
        await api.setCapabilities(.init())
        await app.refresh()
        await api.setCapabilities(receiptGrant)
        await app.refresh()

        // Both publications can arrive before a view reads the sheet binding again.
        XCTAssertNotNil(app.receiptsAPI)
        XCTAssertFalse(homePairing.isPresented(accessGeneration: app.receiptAccessGeneration))
        XCTAssertFalse(settingsPairing.isPresented(accessGeneration: app.receiptAccessGeneration))
    }

    func testReceiptAccessWithdrawalInvalidatesAnOpenFlowAndRetainedAPI() async throws {
        let api = MockHestiaAPI()
        let app = AppState(api: api)
        let grant = receiptGrant(matching: true)
        await api.setCapabilities(grant)
        await app.connect()

        let generation = app.receiptAccessGeneration
        let originalAPI = try XCTUnwrap(app.receiptsAPI)
        let originalFlow = try XCTUnwrap(app.makeReceiptFlow())
        XCTAssertTrue(originalFlow.canMatchReceipts)
        originalFlow.useText("Receipt text")
        await api.setHoldReceiptParse()
        let pendingRequest = Task { try await originalAPI.parseReceiptText("Receipt text", source: .paste) }
        defer { Task { await api.releaseReceiptParse() } }
        try await waitUntil("the receipt request under the original grant") { await api.isReceiptParseHeld }

        await api.setCapabilities(.init())
        await app.refresh()

        let withdrawnGeneration = app.receiptAccessGeneration
        XCTAssertGreaterThan(withdrawnGeneration, generation)
        XCTAssertNil(app.receiptsAPI)
        XCTAssertNil(app.makeReceiptFlow())
        XCTAssertFalse(originalFlow.canMatchReceipts)

        await api.setCapabilities(grant)
        await app.refresh()

        XCTAssertEqual(app.receiptAccessGeneration, withdrawnGeneration)
        XCTAssertFalse(originalFlow.canMatchReceipts)
        let before = await api.count(.capabilities)
        await api.releaseReceiptParse()
        await assertReceiptError(try await pendingRequest.value, .forbidden)
        XCTAssertNil(app.notice)
        let after = await api.count(.capabilities)
        XCTAssertEqual(after, before)

        await api.setReceiptParseResult(try sampleReceipt())
        do {
            _ = try await originalAPI.parseReceiptText("Receipt text", source: .paste)
            XCTFail("The retained API must cancel requests after its grant was withdrawn")
        } catch is CancellationError {
            // The original API must not send a request using the restored grant.
        }
        await originalFlow.send()
        XCTAssertEqual(originalFlow.step, .edit)
        XCTAssertNil(originalFlow.error)
        let obsoleteParseCalls = await api.count(.parseReceipt)
        XCTAssertEqual(obsoleteParseCalls, 1)

        let newFlow = try XCTUnwrap(app.makeReceiptFlow())
        XCTAssertTrue(newFlow.canMatchReceipts)
        newFlow.useText("Receipt text")
        await newFlow.send()
        XCTAssertEqual(newFlow.step, .review)
        XCTAssertFalse(newFlow.candidates.isEmpty)
        let newParseCalls = await api.count(.parseReceipt)
        XCTAssertEqual(newParseCalls, 2)
    }

    func testReceiptFlowMatchGrantUpdatesOpenReview() async throws {
        let api = MockHestiaAPI()
        let app = AppState(api: api)
        let matchingGrant = receiptGrant(matching: true)
        await api.setCapabilities(matchingGrant)
        await api.setReceiptParseResult(try sampleReceipt())
        await app.connect()

        let generation = app.receiptAccessGeneration
        let openReview = try XCTUnwrap(app.makeReceiptFlow())
        openReview.useText("Receipt text")
        await openReview.send()
        XCTAssertEqual(openReview.step, .review)
        XCTAssertFalse(openReview.candidates.isEmpty)
        XCTAssertNotNil(openReview.form.candidate)

        await api.setCapabilities(receiptGrant())
        await app.refresh()

        XCTAssertEqual(app.receiptAccessGeneration, generation)
        XCTAssertNotNil(app.receiptsAPI)
        XCTAssertFalse(openReview.canMatchReceipts)
        XCTAssertEqual(openReview.parsed?.candidates.count, 0)
        XCTAssertNil(openReview.form.candidate)

        let newReview = try XCTUnwrap(app.makeReceiptFlow())
        newReview.useText("Receipt text")
        await newReview.send()
        XCTAssertEqual(newReview.step, .review)
        XCTAssertEqual(newReview.parsed?.candidates.count, 0)
        XCTAssertNil(newReview.form.candidate)

        await api.setCapabilities(matchingGrant)
        await app.refresh()

        XCTAssertEqual(app.receiptAccessGeneration, generation)
        XCTAssertTrue(openReview.canMatchReceipts)
        XCTAssertTrue(openReview.candidates.isEmpty)
        XCTAssertNil(openReview.form.candidate)
    }

    func testReceiptFlowQueuesDraftCleanupAtBoundSessionOrigin() async throws {
        let origin = URL(string: "https://hestia.example:8443")!
        let otherOrigin = URL(string: "https://hestia.example:9443")!
        let session = try testCredentialSessionStore(origin: origin, token: "bound-session")
        let api = MockHestiaAPI()
        await api.setCapabilities(receiptGrant(user: "u"))
        let draft = try sampleReceipt()
        await api.setReceiptParseResult(draft)
        let app = AppState(api: api, sessionStore: session, events: { AsyncStream { $0.finish() } })
        await app.connect()

        let janitor = ReceiptDraftJanitor()
        let flow = try XCTUnwrap(app.makeReceiptFlow(janitor: janitor))
        XCTAssertEqual(flow.scope.origin, origin)
        session.backendURLStore.saveOverride(otherOrigin)
        flow.useText("Receipt text")
        await flow.send()
        XCTAssertEqual(flow.step, .review)
        await flow.abandon()

        let cleanupAPI = MockReceiptsAPI()
        let wrongScope = ReceiptSessionScope(origin: otherOrigin, actor: flow.scope.actor,
                                             ownerKey: flow.scope.ownerKey, credential: flow.scope.credential)
        await janitor.drain(using: cleanupAPI, scope: wrongScope, isScopeCurrent: { $0 == wrongScope })
        let wrongOriginCalls = await cleanupAPI.calls
        XCTAssertTrue(wrongOriginCalls.isEmpty)
        let scope = flow.scope
        await janitor.drain(using: cleanupAPI, scope: scope, isScopeCurrent: { $0 == scope })
        let cleanupCalls = await cleanupAPI.calls
        XCTAssertEqual(cleanupCalls, [.delete(draft.receiptId, draft.version)])
    }

    func testPausedReceiptDenialDoesNotRefreshANewerSession() async throws {
        let api = MockHestiaAPI()
        let app = AppState(api: api, receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()))
        await api.setCapabilities(receiptGrant(user: "old"))
        await app.connect()

        let receipts = try XCTUnwrap(app.receiptsAPI)
        await api.setHoldReceiptParse()
        let request = Task { try await receipts.parseReceiptText("Receipt text", source: .paste) }
        defer { Task { await api.releaseReceiptParse() } }
        try await waitUntil("the old receipt request") { await api.isReceiptParseHeld }

        await app.signOut()
        let newGrant = receiptGrant(user: "new")
        await api.setCapabilities(newGrant)
        await app.connect()
        let before = await api.count(.capabilities)

        await api.releaseReceiptParse()
        await assertReceiptError(try await request.value, .forbidden)

        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.capabilities, newGrant)
        XCTAssertNil(app.notice)
        let after = await api.count(.capabilities)
        XCTAssertEqual(after, before)
    }

    func testPausedReceiptDenialStillRefreshesAfterDiscoveryGenerationChanges() async throws {
        let api = MockHestiaAPI()
        let app = AppState(api: api)
        let grant = receiptGrant()
        await api.setCapabilities(grant)
        await app.connect()

        let generation = app.receiptAccessGeneration
        let receipts = try XCTUnwrap(app.receiptsAPI)
        await api.setHoldReceiptParse()
        let request = Task { try await receipts.parseReceiptText("Receipt text", source: .paste) }
        defer { Task { await api.releaseReceiptParse() } }
        try await waitUntil("the receipt request") { await api.isReceiptParseHeld }

        // Republishing the same receipt-only grants resets discovery without
        // changing the receipt generation or replacing the session.
        await app.refresh()
        XCTAssertEqual(app.capabilities, grant)
        XCTAssertEqual(app.receiptAccessGeneration, generation)
        XCTAssertNil(app.notice)
        let before = await api.count(.capabilities)

        let refreshedGrant = receiptGrant(matching: true)
        await api.setCapabilities(refreshedGrant)
        await api.releaseReceiptParse()
        await assertReceiptError(try await request.value, .forbidden)

        XCTAssertEqual(app.notice, .forbidden)
        try await waitUntil("the receipt denial refresh") { app.capabilities == refreshedGrant }
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(app.receiptAccessGeneration, generation)
        let after = await api.count(.capabilities)
        XCTAssertEqual(after, before + 1)
    }

    private func receiptGrant(user: String? = nil, matching: Bool = false) -> Capabilities {
        var permissions: Set<Permission> = [.budgetReceiptsAdd]
        if matching { permissions.insert(.budgetReceiptsMatch) }
        return Capabilities(user: user, delegatedReceipts: .init(permissions: permissions, canUse: true))
    }

    private func sampleReceipt() throws -> ReceiptParseResult {
        try JSONDecoder().decode(ReceiptParseResult.self, from: Data(sampleParseJSON.utf8))
    }
}
