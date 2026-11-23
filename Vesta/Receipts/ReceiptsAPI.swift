import Foundation
import OpenAPIRuntime

typealias ReceiptParseResult = Components.Schemas.BudgetReceiptParseResult
typealias ReceiptDetail = Components.Schemas.BudgetReceiptDetail
typealias ReceiptCandidate = Components.Schemas.BudgetReceiptCandidate
typealias ReceiptLine = Components.Schemas.BudgetReceiptLine
typealias ReceiptConfirmRequest = Components.Schemas.BudgetReceiptConfirmRequest

/// hestia receipts v1a (`/api/budget/receipts/*`): Vesta sends only on-device
/// OCR text, never the photo. Kept apart from ``HestiaAPI`` so the home-control
/// surface (and its mocks) don't grow with the budget feature.
protocol ReceiptsAPI: Sendable {
    func parseReceiptText(_ text: String) async throws -> ReceiptParseResult
    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail
    /// Discard a draft the user abandoned (otherwise it counts against the
    /// 20-draft quota until hestia sweeps it after 48 h).
    func deleteReceipt(id: String, expectedVersion: Int) async throws
}

/// Receipt failures, mapped from hestia's status + `BudgetError.error` code to
/// copy the user can act on.
enum ReceiptError: LocalizedError, Equatable {
    /// 404 `budget_receipts_disabled` / `budget_disabled`: the owner has not
    /// enabled receipts (or the budget module).
    case disabled
    /// 404 otherwise: the draft expired (48 h) or was deleted.
    case notFound
    /// 403: not an admin owner, or the server still accepts receipts only from
    /// the browser (hestia's bearer path for native clients is not deployed).
    case forbidden
    /// 413 `budget_receipt_quota_exceeded`: 20 open drafts.
    case draftQuota
    /// 413 otherwise (parse-text 48 KiB / confirm 128 KiB body), or caught on
    /// the device before sending (32 KB / 500 lines).
    case tooLarge
    /// 409 `budget_receipt_conflict`: changed elsewhere since it was loaded.
    case versionConflict
    /// 409 `budget_receipt_tx_already_linked`.
    case alreadyLinked
    /// 409 `budget_receipt_stale_source`: the bank transaction changed since preview.
    case staleCandidate
    /// 400 `budget_receipt_total_mismatch`: line totals don't add up to the total.
    case totalMismatch
    /// Other 400s (and 409 `budget_requires_sqlite_users`), with hestia's code.
    case rejected(String)
    /// 503: budget configuration unavailable on the server.
    case unavailable
    /// Transport / auth / unexpected status — reuses the app-wide mapping.
    case api(APIError)

    var title: LocalizedStringResource {
        switch self {
        case .disabled: "Receipts are turned off"
        case .notFound: "Draft no longer exists"
        case .forbidden: "Not allowed"
        case .draftQuota: "Too many open drafts"
        case .tooLarge: "Receipt text is too long"
        case .versionConflict: "Receipt changed elsewhere"
        case .alreadyLinked: "Transaction already has a receipt"
        case .staleCandidate: "Bank transaction changed"
        case .totalMismatch: "Totals don’t add up"
        case .rejected: "Receipt rejected"
        case .unavailable: "Budget unavailable"
        case .api(let error): error.title
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .disabled: "The server owner has not enabled receipts yet."
        case .notFound: "Drafts expire after 48 hours. Scan the receipt again."
        case .forbidden: "Only an admin can add receipts, and the server must allow the app to send them."
        case .draftQuota: "Confirm or discard some drafts on the server, then try again."
        case .tooLarge: "The receipt is too large for the server. Shorten the text and read it again."
        case .versionConflict: "Scan the receipt again to start from the current version."
        case .alreadyLinked: "Pick a different transaction or save the receipt without one."
        case .staleCandidate: "Scan the receipt again to refresh the matching transactions."
        case .totalMismatch: "Fix the receipt text so the item totals add up to the total, then read it again."
        case .rejected: "The server could not accept this receipt."
        case .unavailable: "The server’s budget module is not available right now."
        case .api(let error): error.message
        }
    }

    var technical: String? {
        switch self {
        case .rejected(let code): code
        case .api(let error): error.technical
        default: nil
        }
    }

    var errorDescription: String? { String(localized: message) }

    /// Map an HTTP status + hestia error code (may be nil: middleware can answer
    /// with an empty body).
    static func from(status: Int, code: String?) -> ReceiptError {
        switch (status, code) {
        case (401, _): .api(.unauthorized)
        case (403, _): .forbidden
        case (404, "budget_receipts_disabled"), (404, "budget_disabled"): .disabled
        case (404, _): .notFound
        case (413, "budget_receipt_quota_exceeded"): .draftQuota
        case (413, _): .tooLarge
        case (409, "budget_receipt_conflict"): .versionConflict
        case (409, "budget_receipt_tx_already_linked"): .alreadyLinked
        case (409, "budget_receipt_stale_source"): .staleCandidate
        case (409, let code?): .rejected(code)
        case (400, "budget_receipt_total_mismatch"): .totalMismatch
        case (400, let code?): .rejected(code)
        case (400, nil): .rejected("invalid_request")
        case (503, _): .unavailable
        default: .api(.http(status))
        }
    }

    static func wrap(_ error: any Error) -> ReceiptError {
        if let receipt = error as? ReceiptError { return receipt }
        // hestia's auth middleware can answer 401/403 with an empty body, which
        // the generated client fails to decode before we see the status.
        if let client = error as? ClientError, let status = client.response?.status.code,
           !(200..<300).contains(status) {
            return from(status: status, code: nil)
        }
        return .api(APIError.wrap(error))
    }
}

/// Client-side checks that mirror hestia's `parse-text` limits, so an obviously
/// oversized paste fails instantly instead of after a round trip.
enum ReceiptText {
    static let maxBytes = 32 * 1024
    static let maxLines = 500

    /// Redacts card data, trims, and enforces the limits. Returns the exact text
    /// to send.
    static func prepare(_ raw: String) throws(ReceiptError) -> String {
        let redacted = PANRedactor.redact(raw)
        let trimmed = redacted
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .rejected("empty_text") }
        guard trimmed.utf8.count <= maxBytes,
              trimmed.components(separatedBy: "\n").count <= maxLines else { throw .tooLarge }
        return trimmed
    }
}
