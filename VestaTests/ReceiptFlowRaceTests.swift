import CoreGraphics
import XCTest
@testable import Vesta

@MainActor
final class ReceiptFlowRaceTests: XCTestCase {
    func testAbandonDuringConfirmKeepsTheSavedReceipt() async {
        let api = PausedConfirmAPI()
        let janitor = ReceiptDraftJanitor()
        let flow = ReceiptFlow(api: api, janitor: janitor)
        flow.useText("BIEDRONKA")
        await flow.send()

        let saving = Task { await flow.confirm() }
        await api.gate.waitUntilPaused()
        await flow.abandon()
        await api.gate.resume()
        await saving.value

        let calls = await api.mock.calls
        XCTAssertEqual(calls, [.parse("BIEDRONKA"), .confirm("tx1")])
        XCTAssertEqual(flow.confirmed?.status, .confirmed)
        XCTAssertEqual(flow.confirmed?.version, 2)
        XCTAssertNil(flow.parsed)
        XCTAssertNotEqual(flow.step, .done)
    }

    func testLateOCRDoesNotOverwritePastedText() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let recognizer = PausedRecognizer()
        let flow = ReceiptFlow(api: MockReceiptsAPI(), recognizer: recognizer)

        let recognizing = Task { await flow.recognize([image]) }
        await recognizer.gate.waitUntilPaused()
        flow.useText("Pasted receipt")
        await recognizer.gate.resume()
        await recognizing.value

        XCTAssertEqual(flow.text, "Pasted receipt")
        XCTAssertEqual(flow.step, .edit)
        XCTAssertFalse(flow.isBusy)
    }

    func testSendWaitsForCleanupThatProcessesNewDraftsAndDropsConflicts() async {
        let origin = "https://receipts.example"
        let janitor = ReceiptDraftJanitor()
        let firstAPI = MockReceiptsAPI()
        await firstAPI.holdNextDelete()
        await firstAPI.failDelete(.api(.offline))
        await janitor.enqueue(id: "old", version: 1, server: origin)
        let cleanup = Task { await janitor.drain(using: firstAPI, server: origin) }
        while await firstAPI.calls.isEmpty { await Task.yield() }
        await janitor.enqueue(id: "late", version: 2, server: origin)

        let nextAPI = MockReceiptsAPI()
        await nextAPI.failDelete(.versionConflict)
        let flow = ReceiptFlow(api: nextAPI, janitor: janitor) { origin }
        flow.useText("BIEDRONKA")
        let sending = Task { await flow.send() }
        while !flow.isBusy && flow.step == .edit { await Task.yield() }

        await firstAPI.releaseDelete()
        await cleanup.value
        await sending.value

        let firstCalls = await firstAPI.calls
        let nextCalls = await nextAPI.calls
        let pending = await janitor.pendingCount
        XCTAssertEqual(firstCalls, [.delete("old", 1), .delete("late", 2)])
        XCTAssertEqual(nextCalls, [.delete("old", 1), .delete("late", 2), .parse("BIEDRONKA")])
        XCTAssertEqual(pending, 0)
    }
}

private actor OperationGate {
    private var operation: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation {
            operation = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func waitUntilPaused() async {
        if operation == nil { await withCheckedContinuation { waiter = $0 } }
    }

    func resume() {
        operation?.resume()
        operation = nil
    }
}

private struct PausedConfirmAPI: ReceiptsAPI {
    let mock = MockReceiptsAPI()
    let gate = OperationGate()

    func parseReceiptText(_ text: String, source: ReceiptSourceKind) async throws -> ReceiptParseResult {
        try await mock.parseReceiptText(text, source: source)
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        await gate.pause()
        var receipt = try await mock.confirmReceipt(request)
        receipt.status = .confirmed
        receipt.version += 1
        return receipt
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        try await mock.deleteReceipt(id: id, expectedVersion: expectedVersion)
    }
}

private struct PausedRecognizer: ReceiptTextRecognizing {
    let gate = OperationGate()

    func recognize(_: CGImage) async throws -> [TextFragment] {
        await gate.pause()
        return [TextFragment(text: "Old photo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02))]
    }
}
