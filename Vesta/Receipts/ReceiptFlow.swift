import CoreGraphics
import Foundation
import Observation

/// The editable header of a parsed receipt draft, plus the chosen bank match.
/// Lines are taken from hestia's draft as-is (the server checks
/// `net = gross − discount` and `Σ net = total`; fixing a line means fixing the
/// text and reading it again).
struct ReceiptForm: Equatable {
    var shopName = ""
    var nip = ""
    var kind: ReceiptConfirmRequest.ReceiptKindPayload = .purchase
    var date = Date()
    var time = ""
    var total = ""
    var currency = "PLN"
    var payment: ReceiptConfirmRequest.PaymentMethodPayload = .unknown
    var lines: [ReceiptLine] = []
    /// `entry_reference` of the chosen candidate; nil = save without a bank link.
    var candidateRef: String?

    static let dayFormat: Date.ISO8601FormatStyle = .iso8601.year().month().day()
        .dateSeparator(.dash)

    init() {}

    init(draft: ReceiptDetail, candidates: [ReceiptCandidate]) {
        shopName = draft.rawShopName ?? ""
        nip = draft.rawNip ?? ""
        kind = draft.receiptKind == .refund ? .refund : .purchase
        if let raw = draft.receiptDate, let parsed = try? Date(raw, strategy: Self.dayFormat) { date = parsed }
        time = draft.receiptTime ?? ""
        total = draft.totalAmount ?? ""
        currency = draft.currency ?? "PLN"
        payment = draft.paymentMethod.flatMap(ReceiptConfirmRequest.PaymentMethodPayload.init(rawValue:)) ?? .unknown
        lines = draft.lines
        // Pre-select only an unambiguous match: exactly one candidate on a
        // card/BLIK payment. Otherwise the owner picks (or saves unlinked).
        if candidates.count == 1, payment == .card || payment == .blik {
            candidateRef = candidates[0].entryReference
        }
    }

    /// Cash and mixed payments can't be linked (hestia rejects the link).
    var canLink: Bool { payment != .cash && payment != .mixed }

    /// `Σ net − total` as a decimal string when it isn't zero, else nil. Shown on
    /// review so the owner sees a mismatch before the server rejects it.
    var mismatch: Decimal? {
        guard let totalValue = Self.decimal(total) else { return nil }
        let sum = lines.compactMap { Self.decimal($0.netLineTotal) }.reduce(Decimal(0), +)
        let delta = sum - totalValue
        return delta == 0 ? nil : delta
    }

    var isValid: Bool {
        guard let totalValue = Self.decimal(total), totalValue > 0 else { return false }
        guard nip.isEmpty || nip.count == 10 && nip.allSatisfy(\.isNumber) else { return false }
        guard time.isEmpty || Self.validTime(time) else { return false }
        return currency.count == 3 && mismatch == nil
    }

    func request(receiptID: String, version: Int, candidates: [ReceiptCandidate]) -> ReceiptConfirmRequest {
        let chosen = canLink ? candidates.first { $0.entryReference == candidateRef } : nil
        return ReceiptConfirmRequest(
            currency: currency.uppercased(),
            expectedVersion: version,
            lines: lines.map(Self.input),
            link: chosen.map { .init(accountId: $0.accountId, candidateToken: $0.candidateToken, entryReference: $0.entryReference) },
            paymentMethod: payment,
            rawNip: nip.isEmpty ? nil : nip,
            rawShopName: shopName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : shopName,
            receiptDate: date.formatted(Self.dayFormat),
            receiptId: receiptID,
            receiptKind: kind,
            receiptTime: time.isEmpty ? nil : time,
            totalAmount: total.replacingOccurrences(of: ",", with: ".")
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

    /// Canonical decimal strings only (`12.50`, `-3`); a comma is accepted from
    /// the keyboard. Never goes through Double.
    static func decimal(_ raw: String) -> Decimal? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard normalized.wholeMatch(of: /-?[0-9]+(\.[0-9]+)?/) != nil else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func validTime(_ raw: String) -> Bool {
        raw.wholeMatch(of: /([01][0-9]|2[0-3]):[0-5][0-9]/) != nil
    }
}

/// Capture → edit text → review the parsed draft → confirm. The photo only
/// lives for the duration of ``recognize(_:)``; hestia receives the redacted
/// text and nothing else.
@MainActor
@Observable
final class ReceiptFlow {
    enum Step: Equatable { case capture, edit, review, done }

    var step: Step = .capture
    var text = ""
    var form = ReceiptForm()
    var error: ReceiptError?
    private(set) var isBusy = false
    private(set) var parsed: ReceiptParseResult?
    private(set) var confirmed: ReceiptDetail?

    private let api: any ReceiptsAPI
    private let recognizer: any ReceiptTextRecognizing

    init(api: any ReceiptsAPI, recognizer: any ReceiptTextRecognizing = VisionReceiptRecognizer()) {
        self.api = api
        self.recognizer = recognizer
    }

    var candidates: [ReceiptCandidate] { parsed?.candidates ?? [] }

    /// OCR every page (a long receipt can be several scans), in order, then
    /// redact card data before the text is even shown.
    func recognize(_ pages: [CGImage]) async {
        guard !pages.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            var lines: [String] = []
            for page in pages {
                lines += ReceiptLineOrdering.lines(from: try await recognizer.recognize(page))
            }
            useText(lines.joined(separator: "\n"))
        } catch {
            self.error = .api(.unexpected(error.localizedDescription))
        }
    }

    /// Text from Live Text / the clipboard, or OCR output.
    func useText(_ raw: String) {
        text = PANRedactor.redact(raw)
        error = nil
        step = .edit
    }

    func send() async {
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            let prepared = try ReceiptText.prepare(text)
            await discardDraft()        // re-reading replaces any earlier draft
            let result = try await api.parseReceiptText(prepared)
            parsed = result
            form = ReceiptForm(draft: result.draft, candidates: result.candidates)
            step = .review
        } catch {
            self.error = ReceiptError.wrap(error)
        }
    }

    func confirm() async {
        guard let parsed, form.isValid else { return }
        isBusy = true
        defer { isBusy = false }
        error = nil
        do {
            confirmed = try await api.confirmReceipt(
                form.request(receiptID: parsed.receiptId, version: parsed.version, candidates: parsed.candidates)
            )
            self.parsed = nil
            step = .done
        } catch {
            self.error = ReceiptError.wrap(error)
        }
    }

    /// Back from review to the text: the draft is dropped server-side.
    func backToEdit() async {
        await discardDraft()
        step = .edit
    }

    /// Best effort: an abandoned draft would otherwise count against the
    /// 20-draft quota until hestia's 48 h sweep.
    func discardDraft() async {
        guard let parsed else { return }
        self.parsed = nil
        try? await api.deleteReceipt(id: parsed.receiptId, expectedVersion: parsed.version)
    }
}
