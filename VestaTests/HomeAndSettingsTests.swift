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
}
