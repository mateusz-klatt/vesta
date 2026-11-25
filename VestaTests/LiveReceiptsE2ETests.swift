import XCTest
@testable import Vesta

/// End-to-end check against a real hestia, using Vesta's own networking:
/// redeem a one-time pairing code → parse-text with the device token → delete
/// the draft → revoke the token. Nothing is confirmed, so no receipt is kept.
///
/// Skipped unless both variables are set. xcodebuild forwards them with the
/// `TEST_RUNNER_` prefix:
///
///     TEST_RUNNER_VESTA_E2E_SERVER=https://… TEST_RUNNER_VESTA_E2E_CODE=ABCD2345 \
///       xcodebuild test … -only-testing:VestaTests/LiveReceiptsE2ETests
@MainActor
final class LiveReceiptsE2ETests: XCTestCase {
    func testPairParseDeleteRevokeAgainstLiveHestia() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let serverString = env["VESTA_E2E_SERVER"], let rawCode = env["VESTA_E2E_CODE"] else {
            throw XCTSkip("Set VESTA_E2E_SERVER and VESTA_E2E_CODE to run against a live hestia.")
        }
        let server = try XCTUnwrap(BackendURLStore.canonicalize(serverString))
        let code = try XCTUnwrap(ReceiptPairingCode(rawCode), "not a valid pairing code")

        let hadOverride = BackendURLStore.shared.hasOverride()
        let previous = BackendURLStore.shared.currentEffectiveURL()
        BackendURLStore.shared.saveOverride(server)
        defer {
            if hadOverride { BackendURLStore.shared.saveOverride(previous) } else { BackendURLStore.shared.clearOverride() }
        }

        let store = MemoryDeviceTokenStore()
        let pairing = ReceiptPairing(api: GeneratedDevicePairingAPI(), store: store, serverURL: { server })

        // 1. Redeem.
        try await pairing.pair(code: code, deviceName: "Vesta E2E (simulator)")
        XCTAssertEqual(pairing.status, .paired)
        let stored = try XCTUnwrap(try store.load())
        XCTAssertEqual(stored.server, server)
        XCTAssertFalse(stored.credential.token.isEmpty)

        // 2. parse-text with the device token, then delete the draft.
        let api = APIClient(receiptPairing: pairing)
        let text = """
        SKLEP TESTOWY E2E
        PARAGON FISKALNY
        WODA 1 x 2,50 2,50 A
        SUMA PLN 2,50
        KARTA PŁATNICZA 2,50
        NR KARTY: ************1111
        """
        let prepared = try ReceiptText.prepare(PANRedactor.redact(text))
        XCTAssertFalse(prepared.contains("1111"), "the masked PAN tail must not leave the phone")
        let parsed = try await api.parseReceiptText(prepared, source: .paste)
        XCTAssertFalse(parsed.receiptId.isEmpty)
        try await api.deleteReceipt(id: parsed.receiptId, expectedVersion: parsed.version)

        // 3. Revoke; afterwards the token must no longer work.
        try await pairing.unpair()
        XCTAssertEqual(pairing.status, .notPaired)
        XCTAssertNil(try store.load())
        XCTAssertTrue(try store.loadPendingRevocations().isEmpty, "revoke must have succeeded on the server")
    }
}
