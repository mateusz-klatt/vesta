import CoreGraphics
import XCTest
@testable import Vesta

@MainActor
final class ReceiptFlowRaceTests: XCTestCase {
    func testPhotoLoadingFailureStaysAtCaptureAndAllowsRetry() async throws {
        let api = MockReceiptsAPI()
        let recognizer = StubRecognizer(fragments: [
            TextFragment(text: "Receipt text", box: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.02)),
        ])
        let flow = ReceiptFlow(api: api, recognizer: recognizer)

        await flow.recognize { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(flow.step, .capture)
        XCTAssertEqual(flow.error, .photoUnavailable)
        XCTAssertFalse(flow.isBusy)

        await flow.recognize { [] }
        XCTAssertEqual(flow.error, .photoUnavailable)
        XCTAssertFalse(flow.isBusy)

        let page = try image()
        await flow.recognize { [page] }
        XCTAssertEqual(flow.step, .edit)
        XCTAssertEqual(flow.text, "Receipt text")
        XCTAssertNil(flow.error)
        XCTAssertFalse(flow.isBusy)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testPhotoWithoutReadableTextStaysAtCaptureAndAllowsPaste() async throws {
        let flow = ReceiptFlow(api: MockReceiptsAPI(), recognizer: StubRecognizer(fragments: [
            TextFragment(text: " \n ", box: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.02)),
        ]))
        await flow.recognize([try image()])

        XCTAssertEqual(flow.step, .capture)
        XCTAssertEqual(flow.text, "")
        XCTAssertEqual(flow.error, .noReadableText)
        XCTAssertFalse(flow.isBusy)

        flow.useText("Pasted receipt")
        XCTAssertEqual(flow.step, .edit)
        XCTAssertEqual(flow.text, "Pasted receipt")
        XCTAssertNil(flow.error)
    }

    func testLocalPhotoErrorsOfferRecoveryWithoutPairing() {
        for (error, code) in [(ReceiptError.photoUnavailable, "photo_unavailable"), (.noReadableText, "no_readable_text")] {
            XCTAssertEqual(String(localized: error.title), "Couldn’t read photo")
            XCTAssertEqual(String(localized: error.message),
                           "Choose another photo, scan again, or paste the receipt text.")
            XCTAssertNil(error.technical)
            XCTAssertFalse(error.requiresPairing)
            XCTAssertFalse(error.isAccessDenial)
            XCTAssertEqual(error.reviewCode, code)
        }
    }

    func testCancelledPhotoLoadingIsSilent() async {
        for cancellation in [CancellationError() as any Error, URLError(.cancelled), CocoaError(.userCancelled)] {
            let flow = ReceiptFlow(api: MockReceiptsAPI())
            await flow.recognize { throw cancellation }
            XCTAssertEqual(flow.step, .capture)
            XCTAssertNil(flow.error)
            XCTAssertFalse(flow.isBusy)
        }
    }

    func testLatePhotoLoadFailureDoesNotReplacePastedText() async {
        let gate = OperationGate()
        let flow = ReceiptFlow(api: MockReceiptsAPI())
        let loading = Task {
            await flow.recognize {
                await gate.pause()
                throw ReceiptError.photoUnavailable
            }
        }
        await gate.waitUntilPaused()
        flow.useText("Pasted receipt")
        await gate.resume()
        await loading.value

        XCTAssertEqual(flow.step, .edit)
        XCTAssertEqual(flow.text, "Pasted receipt")
        XCTAssertNil(flow.error)
        XCTAssertFalse(flow.isBusy)
    }

    func testAbandonedPhotoLoadingDoesNotPublishError() async {
        let gate = OperationGate()
        let flow = ReceiptFlow(api: MockReceiptsAPI())
        let loading = Task {
            await flow.recognize {
                await gate.pause()
                throw ReceiptError.photoUnavailable
            }
        }
        await gate.waitUntilPaused()
        await flow.abandon()
        await gate.resume()
        await loading.value

        XCTAssertNil(flow.error)
        XCTAssertFalse(flow.isBusy)
        XCTAssertEqual(flow.step, .capture)
    }

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
        XCTAssertEqual(flow.confirmed?.summary.status, .confirmed)
        XCTAssertEqual(flow.confirmed?.summary.version, 2)
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
        let scope = ReceiptSessionScope.testScope()
        let janitor = ReceiptDraftJanitor()
        let firstAPI = MockReceiptsAPI()
        await firstAPI.holdNextDelete()
        await firstAPI.failDelete(.api(.offline))
        await janitor.enqueue(.init(id: "old", version: 1, scope: scope))
        let cleanup = Task { await janitor.drain(using: firstAPI, scope: scope, isScopeCurrent: { $0 == scope }) }
        while await firstAPI.calls.isEmpty { await Task.yield() }
        await janitor.enqueue(.init(id: "late", version: 2, scope: scope))

        let nextAPI = MockReceiptsAPI()
        await nextAPI.failDelete(.versionConflict)
        let flow = ReceiptFlow(api: nextAPI, janitor: janitor, scope: scope)
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

    func testInFlightReceiptOpsUseCapturedScopeAfterAccountSwitch() async {
        let origin = URL(string: "https://hestia.example")!
        let old = ReceiptSessionScope(origin: origin, actor: "old", ownerKey: "old-ledger", credential: fakeDeviceToken)
        let new = ReceiptSessionScope(origin: origin, actor: "new", ownerKey: "new-ledger", credential: nil)
        let session = ActiveReceiptScope(old)
        let isScopeCurrent: ReceiptScopeValidator = { session.scope == $0 }
        let janitor = ReceiptDraftJanitor()
        let api = MockReceiptsAPI()
        await api.holdNextParse()
        let scanning = ReceiptFlow(api: api, janitor: janitor, scope: old, isScopeCurrent: isScopeCurrent,
                                   isCleanupScopeCurrent: isScopeCurrent)
        scanning.useText("Old receipt")
        let parsing = Task { await scanning.send() }
        while await api.calls.isEmpty { await Task.yield() }

        session.scope = new
        await api.releaseParse()
        await parsing.value
        XCTAssertNil(scanning.parsed)
        XCTAssertEqual(scanning.step, .edit)
        let waitingForOldScope = await janitor.pendingCount
        XCTAssertEqual(waitingForOldScope, 1)
        let newFlow = ReceiptFlow(api: api, janitor: janitor, scope: new, isScopeCurrent: isScopeCurrent,
                                   isCleanupScopeCurrent: isScopeCurrent)
        await newFlow.abandon()
        let callsInNewScope = await api.calls
        XCTAssertEqual(callsInNewScope, [.parse("Old receipt")])

        session.scope = old
        await janitor.enqueue(.init(id: "second-old-draft", version: 1, scope: old))
        await api.holdNextDelete()
        let cleaning = Task { await janitor.drain(using: api, scope: old, isScopeCurrent: isScopeCurrent) }
        while await api.calls.count < 2 { await Task.yield() }
        session.scope = new
        await api.releaseDelete()
        await cleaning.value
        let callsAfterOldDelete = await api.calls
        XCTAssertEqual(callsAfterOldDelete, [.parse("Old receipt"), .delete(sampleReceiptID, 1)])
        let stillWaiting = await janitor.pendingCount
        XCTAssertEqual(stillWaiting, 1)
        let scopes = await api.scopes
        XCTAssertTrue(scopes.allSatisfy { $0 == old })

        session.scope = old
        let confirmAPI = PausedConfirmAPI()
        let reviewing = ReceiptFlow(api: confirmAPI, janitor: janitor, scope: old, isScopeCurrent: isScopeCurrent,
                                   isCleanupScopeCurrent: isScopeCurrent)
        reviewing.useText("Old receipt")
        await reviewing.send()
        let saving = Task { await reviewing.confirm() }
        await confirmAPI.gate.waitUntilPaused()
        session.scope = new
        await confirmAPI.gate.resume()
        await saving.value
        await reviewing.abandon()

        XCTAssertNil(reviewing.confirmed)
        XCTAssertNil(reviewing.parsed)
        XCTAssertNotEqual(reviewing.step, .done)
        let confirmCalls = await confirmAPI.mock.calls
        XCTAssertEqual(confirmCalls, [.delete("second-old-draft", 1), .parse("Old receipt"), .confirm("tx1")])
        let confirmScopes = await confirmAPI.mock.scopes
        XCTAssertTrue(confirmScopes.allSatisfy { $0 == old })
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
private final class ActiveReceiptScope {
    var scope: ReceiptSessionScope
    init(_ scope: ReceiptSessionScope) { self.scope = scope }
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

    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult {
        try await mock.parseReceiptText(text, source: source, scope: scope)
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail {
        var receipt = try await mock.confirmReceipt(request, scope: scope)
        await gate.pause()
        receipt.summary.status = .confirmed
        receipt.summary.version += 1
        return receipt
    }

    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws {
        try await mock.deleteReceipt(id: id, expectedVersion: expectedVersion, scope: scope)
    }
}

private struct PausedRecognizer: ReceiptTextRecognizing {
    let gate = OperationGate()

    func recognize(_: CGImage) async throws -> [TextFragment] {
        await gate.pause()
        return [TextFragment(text: "Old photo", box: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.02))]
    }
}
