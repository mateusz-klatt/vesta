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

/// The editable header of a parsed receipt draft, plus the chosen bank match.
/// Lines are taken from hestia's draft as-is; fixing a line means fixing the
/// text and reading it again.
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

    /// `entry_reference` is unique per account only.
    struct CandidateID: Hashable {
        let account: String
        let entry: String
        init(_ candidate: ReceiptCandidate) { (account, entry) = (candidate.accountId, candidate.entryReference) }
    }

    init() {}

    init(draft: ReceiptDetail, candidates: [ReceiptCandidate]) {
        shopName = draft.rawShopName ?? ""
        nip = draft.rawNip ?? ""
        parsedShopName = shopName
        parsedNIP = nip
        kind = draft.receiptKind == .refund ? .refund : .purchase
        day = draft.receiptDate.flatMap(ReceiptDay.init(iso:))
        time = draft.receiptTime ?? ""
        total = draft.totalAmount ?? ""
        currency = draft.currency ?? "PLN"
        payment = draft.paymentMethod.flatMap(ReceiptConfirmRequest.PaymentMethodPayload.init(rawValue:)) ?? .unknown
        lines = draft.lines
        // Pre-select only an unambiguous match: exactly one candidate on a
        // card/BLIK payment. Otherwise the owner picks (or saves unlinked).
        if candidates.count == 1, payment == .card || payment == .blik {
            candidate = CandidateID(candidates[0])
        }
    }

    /// Cash and mixed payments can't be linked (hestia rejects the link).
    var canLink: Bool { payment != .cash && payment != .mixed }

    /// The shop or NIP was edited, so the shown candidates are stale. hestia
    /// signs the shop name after NFC + whitespace normalisation, so a
    /// whitespace-only edit keeps the match.
    var matchFieldsEdited: Bool {
        outgoingShopName != Self.matchKey(parsedShopName) || nip != parsedNIP
    }

    /// The shop name exactly as confirm sends it: card-redacted, normalised
    /// the way hestia signs it, and capped at 128 characters. The link check
    /// compares this value, so a truncation can't slip past it.
    var outgoingShopName: String {
        String(Self.matchKey(PANRedactor.redact(shopName)).prefix(128))
    }

    static func matchKey(_ shop: String) -> String {
        shop.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The total exactly as it will be sent, or nil if hestia would reject it.
    var normalizedTotal: String? { Self.money(total) }

    /// `|Σ net − total|` when non-zero. Shown on review before the server
    /// rejects it.
    var mismatch: Decimal? {
        guard let totalString = normalizedTotal, let totalValue = Decimal(string: totalString, locale: Self.posix) else { return nil }
        let sum = lines.compactMap { Self.money($0.netLineTotal).flatMap { Decimal(string: $0, locale: Self.posix) } }
            .reduce(Decimal(0), +)
        let delta = sum - totalValue
        return delta == 0 ? nil : abs(delta)
    }

    /// Lines that break hestia's per-line rules (net = gross − discount and the
    /// sign rules per kind); these can't be confirmed as parsed.
    var invalidLines: [Int] { lines.filter { !Self.lineValid($0) }.map(\.lineNo) }

    var isValid: Bool {
        guard day != nil,
              let totalString = normalizedTotal,
              let totalValue = Decimal(string: totalString, locale: Self.posix), totalValue > 0 else { return false }
        guard nip.isEmpty || PANRedactor.validNIP(nip) else { return false }
        guard time.isEmpty || Self.validTime(time) else { return false }
        guard currency.wholeMatch(of: /[A-Z]{3}/) != nil else { return false }
        return mismatch == nil && invalidLines.isEmpty && !lines.isEmpty
    }

    func request(receiptID: String, version: Int, candidates: [ReceiptCandidate]) -> ReceiptConfirmRequest? {
        guard isValid, let day, let total = normalizedTotal else { return nil }
        let chosen = canLink && !matchFieldsEdited ? candidates.first { CandidateID($0) == candidate } : nil
        // Free text leaves the phone too: the same card redaction applies.
        let shop = outgoingShopName
        return ReceiptConfirmRequest(
            currency: currency,
            expectedVersion: version,
            lines: lines.map(Self.input),
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

    static func input(_ line: ReceiptLine) -> Components.Schemas.BudgetReceiptLineInput {
        .init(
            discountAmount: line.discountAmount,
            grossLineTotal: line.grossLineTotal,
            lineKind: .init(rawValue: line.lineKind.rawValue) ?? .other,
            netLineTotal: line.netLineTotal,
            ptuCode: line.ptuCode.flatMap { .init(rawValue: $0.rawValue) },
            quantity: line.quantity,
            rawName: line.rawName,
            rawUnit: line.rawUnit,
            unitPriceRaw: line.unitPriceRaw
        )
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// hestia's money format, canonicalised: optional minus, ≤ 9 integer
    /// digits without leading zeros, ≤ 4 decimals without trailing zeros, dot
    /// separator (`000007,9800` → `7.98`, `8.00` → `8`). Surrounding spaces are
    /// trimmed and a keyboard comma becomes a dot; anything else is rejected.
    /// The same string is validated and sent. Never goes through Double.
    static func money(_ raw: String) -> String? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let match = normalized.wholeMatch(of: /(-?)([0-9]+)(?:\.([0-9]+))?/) else { return nil }
        var integer = String(match.2.drop { $0 == "0" })
        if integer.isEmpty { integer = "0" }
        var fraction = String(match.3 ?? "")
        while fraction.hasSuffix("0") { fraction.removeLast() }
        guard integer.count <= 9, fraction.count <= 4 else { return nil }
        let isZero = integer == "0" && fraction.isEmpty
        let sign = match.1.isEmpty || isZero ? "" : "-"
        return sign + integer + (fraction.isEmpty ? "" : "." + fraction)
    }

    static func lineValid(_ line: ReceiptLine) -> Bool {
        func value(_ raw: String) -> Decimal? { money(raw).flatMap { Decimal(string: $0, locale: posix) } }
        guard let gross = value(line.grossLineTotal), let discount = value(line.discountAmount),
              let net = value(line.netLineTotal), net == gross - discount else { return false }
        switch line.lineKind {
        case .item: return gross >= 0 && discount >= 0 && net >= 0
        case .deposit: return gross != 0 && discount == 0
        case .basketDiscount: return gross < 0 && discount == 0
        case .other: return discount == 0
        }
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

    private typealias Item = (id: String, version: Int, server: String)
    private var queue: [Item] = []
    private var activeDrain: Task<Void, Never>?

    var pendingCount: Int { queue.count }

    /// `server` is the hestia origin the draft lives on: a draft ID only means
    /// something there, so it's only ever deleted through a session on it.
    func enqueue(id: String, version: Int, server: String) { queue.append((id, version, server)) }

    /// Delete everything queued for `server`; failures stay queued for the next
    /// drain, and drafts from another server wait until Vesta points there
    /// again (or expire on their own after 48 h). Wait for any running drain
    /// before checking the queue so callers can parse after cleanup finishes.
    func drain(using api: any ReceiptsAPI, server: String) async {
        while let activeDrain { await activeDrain.value }
        guard queue.contains(where: { $0.server == server }) else { return }
        let task = Task {
            await deleteQueuedDrafts(using: api, server: server)
            activeDrain = nil
        }
        activeDrain = task
        await task.value
    }

    private func deleteQueuedDrafts(using api: any ReceiptsAPI, server: String) async {
        // Finish any new batches before making failed deletes eligible for retry.
        var failed: [Item] = []
        defer { queue.append(contentsOf: failed) }
        while queue.contains(where: { $0.server == server }) {
            let batch = queue.filter { $0.server == server }
            queue.removeAll { $0.server == server }
            for item in batch {
                do {
                    try await api.deleteReceipt(id: item.id, expectedVersion: item.version)
                } catch ReceiptError.notFound, ReceiptError.versionConflict {
                    // Gone or changed elsewhere. This version can't be deleted.
                } catch {
                    failed.append(item)
                }
            }
        }
    }
}

/// Capture → edit text → review the parsed draft → confirm. The photo only
/// lives for the duration of ``recognize(_:)``; hestia receives the redacted
/// text and nothing else.
///
/// One request at a time (``isBusy`` guards every network step). Leaving the
/// flow (``abandon()``) deletes the open draft, including one whose parse
/// response arrives after the sheet is gone; deletes go through
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
    /// The server ``parsed`` was created on.
    private var parsedOn = ""
    private(set) var confirmed: ReceiptDetail?

    private let api: any ReceiptsAPI
    private let recognizer: any ReceiptTextRecognizing
    private let janitor: ReceiptDraftJanitor
    private let server: @MainActor () -> String
    private var abandoned = false
    private var captureGeneration = 0
    private var source: ReceiptSourceKind = .paste

    /// `server` names the hestia origin ``api`` currently talks to (it follows
    /// ``AppConfig/serverURL``); queued deletes are scoped to it.
    init(api: any ReceiptsAPI,
         recognizer: any ReceiptTextRecognizing = VisionReceiptRecognizer(),
         janitor: ReceiptDraftJanitor = .shared,
         server: @escaping @MainActor () -> String = { AppConfig.serverURL.absoluteString }) {
        self.api = api
        self.recognizer = recognizer
        self.janitor = janitor
        self.server = server
    }

    var candidates: [ReceiptCandidate] { parsed?.candidates ?? [] }

    /// OCR every page (a long receipt can be several scans), in order, then
    /// redact card data before the text is even shown.
    func recognize(_ pages: [CGImage]) async {
        await recognize(loading: { pages })
    }

    /// Photo loading and recognition share one busy interval and capture generation.
    func recognize(loading loadPages: @MainActor () async -> [CGImage]) async {
        guard step == .capture, !isBusy, !abandoned else { return }
        let generation = captureGeneration
        isBusy = true
        defer { isBusy = false }
        let pages = await loadPages()
        guard !pages.isEmpty, isCurrentCapture(generation) else { return }
        error = nil
        do {
            var lines: [String] = []
            for page in pages {
                let fragments = try await recognizer.recognize(page)
                guard isCurrentCapture(generation) else { return }
                lines += ReceiptLineOrdering.lines(from: fragments)
            }
            useText(lines.joined(separator: "\n"), source: .localOcr)
        } catch {
            guard isCurrentCapture(generation) else { return }
            self.error = .api(.unexpected(error.localizedDescription))
        }
    }

    private func isCurrentCapture(_ generation: Int) -> Bool {
        generation == captureGeneration && step == .capture && !abandoned
    }

    /// Text from Live Text / the clipboard, or OCR output. An absurdly large
    /// paste is refused before redaction (which is linear, but no reason to
    /// spend it on something hestia will reject anyway).
    func useText(_ raw: String, source: ReceiptSourceKind = .paste) {
        captureGeneration += 1
        guard raw.utf8.count <= ReceiptText.maxBytes * 2 else {
            error = .tooLarge
            return
        }
        text = PANRedactor.redact(raw)
        self.source = source
        error = nil
        step = .edit
    }

    func startOver() {
        guard step == .edit, !isBusy, !abandoned else { return }
        captureGeneration += 1
        text = ""
        source = .paste
        step = .capture
    }

    func send() async {
        guard !isBusy, !abandoned else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let prepared = try ReceiptText.prepare(text)
            let source = source
            let origin = server()
            await deleteCurrentDraft()      // re-reading replaces any earlier draft
            guard !abandoned else { return } // closed while cleanup ran: send nothing
            let result = try await api.parseReceiptText(prepared, source: source)
            if abandoned {                  // the sheet closed while we waited
                await janitor.enqueue(id: result.receiptId, version: result.version, server: origin)
                await janitor.drain(using: api, server: server())
                return
            }
            parsed = result
            parsedOn = origin
            form = ReceiptForm(draft: result.draft, candidates: result.candidates)
            step = .review
        } catch {
            self.error = ReceiptError.wrap(error)
        }
    }

    func confirm() async {
        guard !isBusy, !abandoned, let parsed,
              let request = form.request(receiptID: parsed.receiptId, version: parsed.version, candidates: parsed.candidates)
        else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            confirmed = try await api.confirmReceipt(request)
            self.parsed = nil
            guard !abandoned else { return } // Save succeeded after the sheet closed.
            step = .done
        } catch {
            if abandoned {
                await deleteCurrentDraft()
            } else {
                self.error = ReceiptError.wrap(error)
            }
        }
    }

    /// Back from review to the text: the draft is dropped server-side.
    func backToEdit() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await deleteCurrentDraft()
        step = .edit
    }

    /// The sheet is closing. In-flight operations own their draft cleanup.
    /// Otherwise discard the current draft and retry earlier failed deletes.
    func abandon() async {
        abandoned = true
        guard !isBusy else { return }
        await deleteCurrentDraft()
    }

    /// Delete the open draft plus any earlier failed deletes. Best effort: a
    /// draft hestia can't delete now expires after 48 h anyway.
    private func deleteCurrentDraft() async {
        if let parsed {
            self.parsed = nil
            await janitor.enqueue(id: parsed.receiptId, version: parsed.version, server: parsedOn)
        }
        await janitor.drain(using: api, server: server())
    }
}
