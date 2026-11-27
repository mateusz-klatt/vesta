import CoreGraphics
import Foundation
import Observation

/// A calendar day (`YYYY-MM-DD`) with no time zone, so a draft dated the 22nd
/// stays the 22nd wherever the phone is. Converted to/from `Date` only for the
/// picker, always through the same local calendar.
struct ReceiptDay: Equatable {
    let year: Int, month: Int, day: Int

    init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard iso.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil, parts.count == 3 else { return nil }
        var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        components.calendar = Self.calendar
        guard components.isValidDate else { return nil }
        (year, month, day) = (parts[0], parts[1], parts[2])
    }

    init(date: Date) {
        let components = Self.calendar.dateComponents([.year, .month, .day], from: date)
        (year, month, day) = (components.year!, components.month!, components.day!)
    }

    /// Local midnight of this day, for the DatePicker.
    var date: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: day))! }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }
}

extension ReceiptCandidate {
    var scanDisplay: (date: String, amount: String) {
        let date = transactionDate ?? bookingDate ?? valueDate ?? "—"
        return (date, "\(displayAmount) \(currency)")
    }
}

/// The editable header of a parsed receipt draft, plus the chosen bank match.
/// To change the parsed items in the scan UI, edit the text and read it again.
struct ReceiptForm: Equatable {
    var shopName = ""
    var nip = ""
    var kind: ReceiptConfirmRequest.ReceiptKindPayload = .purchase
    /// nil when hestia couldn't read a date: the owner must pick one.
    var day: ReceiptDay?
    var time = ""
    var total = ""
    var currency = "PLN"
    var payment: ReceiptConfirmRequest.PaymentMethodPayload = .unknown
    var lines: [ReceiptLine] = []
    /// ``CandidateID`` of the chosen bank transaction; nil = save unlinked.
    var candidate: CandidateID?

    /// Shop name and NIP as parsed. hestia's candidate tokens are bound to them,
    /// so editing either one invalidates every match shown.
    private(set) var parsedShopName = ""
    private(set) var parsedNIP = ""
    private var documentKind: BudgetReceiptSummaryWire.DocumentKindPayload?
    private(set) var canConfirmStatus = true
    private(set) var canConfirmKind = true
    private var invoiceNumber: String?
    private var parsedLines: [ReceiptLine] = []

    /// `entry_reference` is unique per account only.
    struct CandidateID: Hashable {
        let account: String
        let entry: String
        init(_ candidate: ReceiptCandidate) { (account, entry) = (candidate.accountId, candidate.entryReference) }
    }

    init() {}

    init(draft: ReceiptDetail, candidates: [ReceiptCandidate]) {
        let summary = draft.summary
        shopName = summary.rawShopName ?? ""
        nip = summary.rawNip ?? ""
        parsedShopName = shopName
        parsedNIP = nip
        if let confirmKind = summary.receiptKind.confirmValue {
            kind = confirmKind
        } else {
            canConfirmKind = false
        }
        day = summary.receiptDate.flatMap(ReceiptDay.init(iso:))
        time = summary.receiptTime ?? ""
        total = summary.totalAmount ?? ""
        currency = summary.currency ?? "PLN"
        payment = summary.paymentMethod.flatMap(ReceiptConfirmRequest.PaymentMethodPayload.init(rawValue:)) ?? .unknown
        documentKind = summary.documentKind
        canConfirmStatus = summary.status != .unknown
        invoiceNumber = summary.invoiceNumber
        parsedLines = draft.lines
        lines = draft.lines
        // Pre-select only an unambiguous match: exactly one candidate on a
        // card/BLIK payment. Otherwise the owner picks (or saves unlinked).
        if !draft.hasUnknownReviewMetadata, candidates.count == 1,
           let match = candidates.first, match.matchStrength != .unknown,
           payment == .card || payment == .blik {
            candidate = CandidateID(match)
        }
    }

    /// Cash and mixed payments can't be linked (hestia rejects the link).
    var canLink: Bool { payment != .cash && payment != .mixed }

    /// The shop or NIP was edited, so the shown candidates are stale. hestia
    /// signs the shop name after NFC + whitespace normalisation, so a
    /// whitespace-only edit keeps the match.
    var matchFieldsEdited: Bool {
        outgoingShopName != ReceiptConfirmLines.normalizeConfirmName(parsedShopName) || nip != parsedNIP
    }

    /// The shop name exactly as confirm sends it: card-redacted, normalised
    /// the way hestia signs it, and capped at 128 characters. The link check
    /// compares this value, so a truncation can't slip past it.
    var outgoingShopName: String {
        let name = ReceiptConfirmLines.normalizeConfirmName(PANRedactor.redact(shopName))
        return String(name.unicodeScalars.prefix(ReceiptConfirmLines.maxNameLength))
    }

    private var normalizedTotal: String? { ReceiptConfirmLines.normalizeConfirmTotal(total) }

    var totalAdjustment: ReceiptTotalAdjustment? {
        guard case .success(let plan) = linePlan else { return nil }
        return plan.adjustment
    }

    var confirmLineError: ReceiptError? {
        guard case .failure(let error) = linePlan else { return nil }
        return error.receiptError
    }

    var isValid: Bool {
        guard hasValidHeader, case .success = linePlan else { return false }
        return true
    }

    private var hasValidHeader: Bool {
        guard canConfirmStatus, canConfirmKind, day != nil else { return false }
        guard nip.isEmpty || PANRedactor.validNIP(nip) else { return false }
        guard time.isEmpty || Self.validTime(time) else { return false }
        return currency.wholeMatch(of: /[A-Z]{3}/) != nil
    }

    private var linePlan: Result<ReceiptConfirmLinePlan, ReceiptConfirmLineError>? {
        guard canConfirmKind, let total = normalizedTotal else { return nil }
        return linePlan(total: total)
    }

    private func linePlan(total: String) -> Result<ReceiptConfirmLinePlan, ReceiptConfirmLineError> {
        return Result { () throws(ReceiptConfirmLineError) in
            try ReceiptConfirmLines.planConfirmLines(
                documentKind: documentKind, originalLines: parsedLines, draftLines: lines, total: total
            )
        }
    }

    func request(receiptID: String, version: Int, candidates: [ReceiptCandidate]) -> ReceiptConfirmRequest? {
        guard hasValidHeader, let day, let total = normalizedTotal,
              case .success(let plan) = linePlan(total: total) else { return nil }
        let chosen = canLink && !matchFieldsEdited ? candidates.first { CandidateID($0) == candidate } : nil
        // Free text leaves the phone too: the same card redaction applies.
        let shop = outgoingShopName
        let requestLines = ReceiptConfirmLines.linesForRequest(
            plan, documentKind: documentKind, originalLines: parsedLines, draftLines: lines,
            invoiceNumber: invoiceNumber, draftShopName: shopName,
            storedShopName: parsedShopName, total: total
        )
        return ReceiptConfirmRequest(
            currency: currency,
            expectedVersion: version,
            lines: requestLines,
            link: chosen.map { .init(accountId: $0.accountId, candidateToken: $0.candidateToken, entryReference: $0.entryReference) },
            paymentMethod: payment,
            rawNip: nip.isEmpty ? nil : nip,
            rawShopName: shop.isEmpty ? nil : shop,
            receiptDate: day.iso,
            receiptId: receiptID,
            receiptKind: kind,
            receiptTime: time.isEmpty ? nil : time,
            totalAmount: total
        )
    }

    static func validTime(_ raw: String) -> Bool {
        raw.wholeMatch(of: /([01][0-9]|2[0-3]):[0-5][0-9]/) != nil
    }
}

/// Drafts to delete on hestia, kept outside any one sheet so a cleanup that
/// fails (or is still in flight when the sheet closes) is retried by the next
/// flow instead of being lost with the discarded one. Draining is serialised.
actor ReceiptDraftJanitor {
    static let shared = ReceiptDraftJanitor()

    struct Item: Sendable {
        let id: String
        let version: Int
        let scope: ReceiptSessionScope
    }
    private var queue: [Item] = []
    private var activeDrain: Task<Void, Never>?

    var pendingCount: Int { queue.count }

    func enqueue(_ item: Item) { queue.append(item) }

    /// Retry deletes only under their original scope. Wait for a running drain
    /// before checking the queue so parsing can follow any pending cleanup.
    func drain(using api: any ReceiptsAPI, scope: ReceiptSessionScope,
               isScopeCurrent: @escaping ReceiptScopeValidator) async {
        while let activeDrain { await activeDrain.value }
        guard queue.contains(where: { $0.scope == scope }) else { return }
        let task = Task {
            await deleteQueuedDrafts(using: api, scope: scope, isScopeCurrent: isScopeCurrent)
            activeDrain = nil
        }
        activeDrain = task
        await task.value
    }

    private func deleteQueuedDrafts(using api: any ReceiptsAPI, scope: ReceiptSessionScope,
                                    isScopeCurrent: ReceiptScopeValidator) async {
        // Finish any new batches before making failed deletes eligible for retry.
        var failed: [Item] = []
        defer { queue.append(contentsOf: failed) }
        while queue.contains(where: { $0.scope == scope }) {
            let batch = queue.filter { $0.scope == scope }
            queue.removeAll { $0.scope == scope }
            for (index, item) in batch.enumerated() {
                guard await isScopeCurrent(item.scope) else {
                    failed.append(contentsOf: batch[index...])
                    return
                }
                let shouldRetry: Bool
                do {
                    try await api.deleteReceipt(id: item.id, expectedVersion: item.version, scope: item.scope)
                    shouldRetry = false
                } catch ReceiptError.notFound, ReceiptError.versionConflict, ReceiptError.alreadySubmitted {
                    // Gone or changed elsewhere. This version can't be deleted.
                    shouldRetry = false
                } catch {
                    shouldRetry = true
                }
                guard await isScopeCurrent(item.scope) else {
                    if shouldRetry { failed.append(item) }
                    failed.append(contentsOf: batch.dropFirst(index + 1))
                    return
                }
                if shouldRetry { failed.append(item) }
            }
        }
    }
}

/// Capture → edit text → review the parsed draft → confirm. Decoded photos
/// live only during recognition. Hestia receives the redacted text.
///
/// One request at a time (``isBusy`` guards every network step). Leaving the
/// flow (``abandon()``) cancels OCR and deletes the open draft, including one
/// whose parse response arrives after the sheet is gone; deletes go through
/// ``ReceiptDraftJanitor`` so a failed one is retried by a later flow.
@MainActor
@Observable
final class ReceiptFlow {
    enum Step: Equatable { case capture, edit, review, done }

    private(set) var step: Step = .capture
    var text = ""
    var form = ReceiptForm()
    var error: ReceiptError?
    private(set) var isBusy = false
    private(set) var parsed: ReceiptParseResult?
    private(set) var confirmed: ReceiptDetail?
    private(set) var linkOutcomeMessage: LocalizedStringResource?
    private var overlapReview: ReceiptPhotoRecognition.OverlapReview?
    let scope: ReceiptSessionScope

    private let api: any ReceiptsAPI
    private let recognizer: any ReceiptTextRecognizing
    private let janitor: ReceiptDraftJanitor
    private let allowsMatching: @MainActor () -> Bool
    private let isScopeCurrent: ReceiptScopeValidator
    private let isCleanupScopeCurrent: ReceiptScopeValidator
    private var abandoned = false
    private var captureGeneration = 0
    private var recognitionTask: Task<Void, Never>?
    private var source: ReceiptSourceKind = .paste

    init(api: any ReceiptsAPI,
         recognizer: any ReceiptTextRecognizing = VisionReceiptRecognizer(),
         allowsMatching: @escaping @MainActor () -> Bool = { true },
         janitor: ReceiptDraftJanitor = .shared,
         scope: ReceiptSessionScope,
         isScopeCurrent: @escaping ReceiptScopeValidator,
         isCleanupScopeCurrent: @escaping ReceiptScopeValidator) {
        self.api = api
        self.recognizer = recognizer
        self.janitor = janitor
        self.allowsMatching = allowsMatching
        self.scope = scope
        self.isScopeCurrent = isScopeCurrent
        self.isCleanupScopeCurrent = isCleanupScopeCurrent
    }

    var canMatchReceipts: Bool { isScopeCurrent(scope) && allowsMatching() }
    var candidates: [ReceiptCandidate] { canMatchReceipts ? parsed?.candidates ?? [] : [] }
    var overlapReviewMessage: LocalizedStringResource? {
        switch overlapReview {
        case .textAlignment:
            "Photo overlap was estimated. Check the receipt lines before confirming."
        case .uncertain:
            "Some photos may overlap. Check the receipt lines before confirming."
        case nil:
            nil
        }
    }

    func updateMatchAccess() {
        guard !canMatchReceipts else { return }
        parsed?.candidates = []
        form.candidate = nil
    }

    /// OCR the images in order, then redact card data before showing the text.
    func recognize(_ pages: [CGImage]) async {
        await recognize(pageCount: pages.count) { pages[$0] }
    }

    /// Load and read each photo before loading the next, under one capture generation.
    func recognize(pageCount: Int, loading loadPage: @escaping @MainActor (Int) async throws -> CGImage) async {
        await recognize { generation in
            try await self.readPhotos(pageCount: pageCount, generation: generation, loading: loadPage)
        }
    }

    /// Keep the batch loader used by existing callers within the same busy interval.
    func recognize(loading loadPages: @escaping @MainActor () async throws -> [CGImage]) async {
        await recognize { generation in
            let pages = try await loadPages()
            return try await self.readPhotos(pageCount: pages.count, generation: generation) { pages[$0] }
        }
    }

    private func recognize(
        reading read: @escaping @MainActor (Int) async throws -> ReceiptPhotoRecognition.Result
    ) async {
        guard step == .capture, !isBusy, !abandoned, isCurrent else { return }
        let generation = captureGeneration
        isBusy = true
        error = nil
        let task = Task { await performRecognition(reading: read, generation: generation) }
        recognitionTask = task
        defer {
            recognitionTask = nil
            isBusy = false
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func readPhotos(
        pageCount: Int, generation: Int, loading loadPage: @MainActor (Int) async throws -> CGImage
    ) async throws -> ReceiptPhotoRecognition.Result {
        guard pageCount > 0 else { throw ReceiptError.photoUnavailable }
        return try await ReceiptPhotoRecognition.read(pageCount: pageCount, loadPage: { index in
            guard isCurrentCapture(generation) else { throw CancellationError() }
            let page = try await loadPage(index)
            guard isCurrentCapture(generation) else { throw CancellationError() }
            return page
        }, recognizer: recognizer)
    }

    private func performRecognition(
        reading read: @MainActor (Int) async throws -> ReceiptPhotoRecognition.Result, generation: Int
    ) async {
        guard isCurrentCapture(generation) else { return }
        do {
            let result = try await read(generation)
            guard isCurrentCapture(generation) else { return }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                error = .noReadableText
                return
            }
            useText(result.text, source: .localOcr, overlapReview: result.overlapReview)
        } catch {
            guard isCurrentCapture(generation), !APIError.isCancellation(error),
                  (error as? CocoaError)?.code != .userCancelled else { return }
            self.error = .photoUnavailable
        }
    }

    private func isCurrentCapture(_ generation: Int) -> Bool {
        generation == captureGeneration && step == .capture && !abandoned && isCurrent
    }

    private var isCurrent: Bool { !Task.isCancelled && isScopeCurrent(scope) }

    /// Text from Live Text / the clipboard, or OCR output. An absurdly large
    /// paste is refused before redaction (which is linear, but no reason to
    /// spend it on something hestia will reject anyway).
    func useText(_ raw: String, source: ReceiptSourceKind = .paste,
                 overlapReview: ReceiptPhotoRecognition.OverlapReview? = nil) {
        guard !abandoned, isCurrent else { return }
        captureGeneration += 1
        guard raw.utf8.count <= ReceiptText.maxBytes * 2 else {
            error = .tooLarge
            return
        }
        linkOutcomeMessage = nil
        text = PANRedactor.redact(raw)
        self.overlapReview = overlapReview
        self.source = source
        error = nil
        if source == .localOcr {
            // Warn as soon as OCR finishes, and leave the text editable so the
            // user can shorten it. Send validates again after any edits.
            do {
                _ = try ReceiptText.prepareRedacted(text)
            } catch {
                self.error = error
            }
        }
        step = .edit
    }

    func startOver() {
        guard step == .edit, !isBusy, !abandoned, isCurrent else { return }
        captureGeneration += 1
        linkOutcomeMessage = nil
        text = ""
        overlapReview = nil
        source = .paste
        step = .capture
    }

    func send() async {
        guard step == .edit, !isBusy, !abandoned, isCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let prepared = try ReceiptText.prepare(text)
            let source = source
            await deleteCurrentDraft()      // re-reading replaces any earlier draft
            guard !abandoned, isCurrent else { return }
            var result = try await api.parseReceiptText(prepared, source: source, scope: scope)
            if abandoned || !isCurrent {
                await drainCleanup(adding: result)
                return
            }
            if !canMatchReceipts { result.candidates = [] }
            parsed = result
            form = ReceiptForm(draft: result.draft, candidates: result.candidates)
            step = .review
        } catch is CancellationError {
            return
        } catch {
            guard !abandoned, isCurrent else { return }
            self.error = ReceiptError.wrap(error)
        }
    }

    func confirm() async {
        guard step == .review, !isBusy, !abandoned, isCurrent, let parsed else { return }
        let candidates = self.candidates
        guard let request = form.request(receiptID: parsed.receiptId, version: parsed.version, candidates: candidates) else {
            if let lineError = form.confirmLineError { error = lineError }
            return
        }
        let linkedCandidate = request.link.flatMap { link in
            candidates.first {
                $0.accountId == link.accountId && $0.entryReference == link.entryReference
                    && $0.candidateToken == link.candidateToken
            }
        }
        isBusy = true
        defer { isBusy = false }
        error = nil
        let receipt: ReceiptDetail?
        do {
            receipt = try await api.confirmReceipt(request, scope: scope)
        } catch ReceiptError.alreadySubmitted {
            receipt = nil
        } catch {
            if abandoned {
                await deleteCurrentDraft()
            } else if isCurrent, !(error is CancellationError) {
                self.error = ReceiptError.wrap(error)
            }
            return
        }
        finishConfirmation(with: receipt, sentLink: request.link != nil, candidate: linkedCandidate)
    }

    private func finishConfirmation(with receipt: ReceiptDetail?, sentLink: Bool, candidate: ReceiptCandidate?) {
        let mayPublish = isCurrent
        // The server already settled this draft, even if its sheet is obsolete.
        parsed = nil
        guard mayPublish else { return }
        confirmed = receipt
        guard !abandoned else { return }
        let summary = receipt?.summary
        // An already-submitted response has no receipt to inspect.
        let isLinked = summary?.linked ?? sentLink
        let hasDifferentLink = if let candidate, let accountId = summary?.linkedAccountId,
                                  let entryRef = summary?.linkedEntryRef {
            accountId != candidate.accountId || entryRef != candidate.entryReference
        } else {
            false
        }
        if !isLinked {
            linkOutcomeMessage = "Waiting for the bank transaction"
        } else if summary != nil, let candidate, !hasDifferentLink {
            let display = candidate.scanDisplay
            linkOutcomeMessage = "Linked to transaction: \(display.date) \(display.amount)"
        } else {
            linkOutcomeMessage = "Linked to transaction"
        }
        step = .done
    }

    /// Back from review to the text: the draft is dropped server-side.
    func backToEdit() async {
        guard !isBusy, !abandoned, isCurrent else { return }
        isBusy = true
        defer { isBusy = false }
        await deleteCurrentDraft()
        guard !abandoned, isCurrent else { return }
        linkOutcomeMessage = nil
        step = .edit
    }

    /// The sheet is closing. In-flight operations own their draft cleanup.
    /// Otherwise discard the current draft and retry earlier failed deletes.
    func abandon() async {
        abandoned = true
        recognitionTask?.cancel()
        guard !isBusy else { return }
        await deleteCurrentDraft()
    }

    /// Delete the open draft plus any earlier failed deletes. Best effort: a
    /// draft hestia can't delete now expires after 48 h anyway.
    private func deleteCurrentDraft() async {
        let draft = parsed
        parsed = nil
        await drainCleanup(adding: draft)
    }

    private func drainCleanup(adding draft: ReceiptParseResult?) async {
        if let draft, draft.draft.summary.status != .unknown {
            await janitor.enqueue(.init(id: draft.receiptId, version: draft.version, scope: scope))
        }
        guard isCleanupScopeCurrent(scope) else { return }
        await janitor.drain(using: api, scope: scope, isScopeCurrent: isCleanupScopeCurrent)
    }
}
