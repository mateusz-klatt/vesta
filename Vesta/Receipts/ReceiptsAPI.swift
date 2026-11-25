import Foundation
import OpenAPIRuntime

typealias ReceiptParseResult = Components.Schemas.BudgetReceiptParseResult
typealias ReceiptDetail = Components.Schemas.BudgetReceiptDetail
typealias ReceiptCandidate = Components.Schemas.BudgetReceiptCandidate
typealias ReceiptLine = Components.Schemas.BudgetReceiptLine
typealias ReceiptConfirmRequest = Components.Schemas.BudgetReceiptConfirmRequest
typealias ReceiptSourceKind = Components.Schemas.BudgetReceiptParseTextRequest.SourceKindPayload

/// The device credential and ledger that a receipt operation was started with.
/// A legacy code credential has no owner key, but still has a session actor
/// when the backend requires sign-in.
struct ReceiptSessionScope: Equatable, Sendable {
    let origin: URL
    let actor: String?
    let ownerKey: String?
    let credential: ReceiptDeviceToken?

    func matches(_ active: StoredReceiptDeviceToken, actor: String?) -> Bool {
        OriginMatcher.matches(origin, active.server) && self.actor == actor &&
            ownerKey == active.ownerKey && credential == active.credential
    }
}

typealias ReceiptScopeValidator = @MainActor @Sendable (ReceiptSessionScope) -> Bool

/// Vesta submits receipt text from on-device OCR or paste. Kept apart from
/// ``HestiaAPI`` so the home-control surface stays independent of receipts.
protocol ReceiptsAPI: Sendable {
    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult
    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail
    /// Discard a draft the user abandoned (otherwise it counts against the
    /// 20-draft quota until hestia sweeps it after 48 h).
    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws
}

extension ReceiptsAPI {
    func parseReceiptText(_ text: String, source: ReceiptSourceKind) async throws -> ReceiptParseResult {
        try await parseReceiptText(text, source: source, scope: nil)
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest) async throws -> ReceiptDetail {
        try await confirmReceipt(request, scope: nil)
    }

    func deleteReceipt(id: String, expectedVersion: Int) async throws {
        try await deleteReceipt(id: id, expectedVersion: expectedVersion, scope: nil)
    }
}

/// Reports a denial only while the initiating app session still owns the scope.
struct DenialReportingReceiptsAPI: ReceiptsAPI {
    typealias FailureHandler = @MainActor @Sendable (ReceiptError, ReceiptSessionScope) -> Void

    private let api: any ReceiptsAPI
    private let scope: ReceiptSessionScope
    private let isScopeCurrent: ReceiptScopeValidator
    private let isCleanupScopeCurrent: ReceiptScopeValidator
    private let onFailure: FailureHandler

    init(api: any ReceiptsAPI, scope: ReceiptSessionScope,
         isScopeCurrent: @escaping ReceiptScopeValidator, isCleanupScopeCurrent: @escaping ReceiptScopeValidator,
         onFailure: @escaping FailureHandler) {
        self.api = api
        self.scope = scope
        self.isScopeCurrent = isScopeCurrent
        self.isCleanupScopeCurrent = isCleanupScopeCurrent
        self.onFailure = onFailure
    }

    func parseReceiptText(_ text: String, source: ReceiptSourceKind, scope: ReceiptSessionScope?) async throws -> ReceiptParseResult {
        try await reportingDenial(scope, valid: isScopeCurrent) {
            try await api.parseReceiptText(text, source: source, scope: self.scope)
        }
    }

    func confirmReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope?) async throws -> ReceiptDetail {
        try await reportingDenial(scope, valid: isScopeCurrent) {
            try await api.confirmReceipt(request, scope: self.scope)
        }
    }

    func deleteReceipt(id: String, expectedVersion: Int, scope: ReceiptSessionScope?) async throws {
        try await reportingDenial(scope, valid: isCleanupScopeCurrent) {
            try await api.deleteReceipt(id: id, expectedVersion: expectedVersion, scope: self.scope)
        }
    }

    private func reportingDenial<Result: Sendable>(
        _ requested: ReceiptSessionScope?, valid: ReceiptScopeValidator,
        _ operation: () async throws -> Result
    ) async throws -> Result {
        guard requested == nil || requested == scope, await valid(scope) else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            let result = try await operation()
            // Explicitly scoped callers revalidate on receipt, so a late parse can
            // queue the returned draft on its original scope before discarding it.
            if requested == nil, !(await valid(scope)) { throw CancellationError() }
            return result
        } catch let error as ReceiptError {
            switch error {
            case .forbidden, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken:
                await reportFailure(error, valid: valid)
            default:
                break
            }
            throw error
        }
    }

    @MainActor
    private func reportFailure(_ error: ReceiptError, valid: ReceiptScopeValidator) {
        if !Task.isCancelled, valid(scope) { onFailure(error, scope) }
    }
}

/// Receipt failures, mapped from hestia's status + `BudgetError.error` code to
/// copy the user can act on.
enum ReceiptError: LocalizedError, Equatable {
    /// 404 `budget_receipts_disabled` / `budget_disabled`: the owner has not
    /// enabled receipts (or the budget module).
    case disabled
    /// 404 otherwise: the draft expired (48 h) or was deleted.
    case notFound
    /// 403: the server denied access to receipts.
    case forbidden
    /// No usable device token is available for the request.
    case pairAgain
    case expiredDeviceToken
    case revokedDeviceToken
    case invalidDeviceToken
    /// 400 `budget_auth_ambiguous`: hestia saw multiple credentials.
    case ambiguousAuth
    /// 429: hestia's receipt rate limit.
    case rateLimited
    /// 413 `budget_receipt_quota_exceeded`: 20 open drafts.
    case draftQuota
    /// 413 otherwise (parse-text 48 KiB / confirm 128 KiB body), or caught on
    /// the device before sending (32 KB / 500 lines).
    case tooLarge
    /// 409 `budget_receipt_conflict`: changed elsewhere since it was loaded.
    case versionConflict
    /// 409 `budget_receipt_tx_already_linked`.
    case alreadyLinked
    /// 409 `already_submitted`: confirmation already succeeded.
    case alreadySubmitted
    /// 409 `budget_receipt_stale_source`: the bank transaction changed since preview.
    case staleCandidate
    /// 400 `budget_receipt_total_mismatch`: line totals don't add up to the total.
    case totalMismatch
    /// 409 `device_token_limit_reached`: hestia already has 5 active devices
    /// and won't evict one for a password login.
    case deviceLimit
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
        case .forbidden: APIError.forbidden.title
        case .pairAgain, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: "Pair again"
        case .ambiguousAuth: "Multiple credentials"
        case .rateLimited: "Receipt limit reached"
        case .draftQuota: "Too many open drafts"
        case .tooLarge: "Receipt text is too long"
        case .versionConflict: "Receipt changed elsewhere"
        case .alreadyLinked: "Transaction already has a receipt"
        case .alreadySubmitted: "Receipt saved"
        case .staleCandidate: "Bank transaction changed"
        case .totalMismatch: "Totals don’t add up"
        case .deviceLimit: "Device limit reached"
        case .rejected: "Receipt rejected"
        case .unavailable: "Budget unavailable"
        case .api(let error): error.title
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .disabled: "The server owner has not enabled receipts yet."
        case .notFound: "Drafts expire after 48 hours. Scan the receipt again."
        case .forbidden: APIError.forbidden.message
        case .pairAgain, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: "Pair this iPhone with hestia to continue."
        case .ambiguousAuth: "The server received more than one credential. Check your connection and try again."
        case .rateLimited: "Too many receipts, try again in a minute"
        case .draftQuota: "Confirm or discard some drafts on the server, then try again."
        case .tooLarge: "The receipt is too large for the server. Shorten the text and read it again."
        case .versionConflict: "Scan the receipt again to start from the current version."
        case .alreadyLinked: "Pick a different transaction or save the receipt without one."
        case .alreadySubmitted: "Receipt saved"
        case .staleCandidate: "Scan the receipt again to refresh the matching transactions."
        case .totalMismatch: "Fix the receipt text so the item totals add up to the total, then read it again."
        case .deviceLimit: DevicePairingError.deviceLimit.message
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

    var requiresPairing: Bool {
        switch self {
        case .pairAgain, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: true
        default: false
        }
    }

    /// Map an HTTP status + hestia error code (may be nil: middleware can answer
    /// with an empty body).
    static func from(status: Int, code: String?) -> ReceiptError {
        switch (status, code) {
        case (401, "device_token_expired"): .expiredDeviceToken
        case (401, "device_token_revoked"): .revokedDeviceToken
        case (401, "device_token_invalid"): .invalidDeviceToken
        case (401, _): .api(.unauthorized)
        case (403, _): .forbidden
        case (404, "budget_receipts_disabled"), (404, "budget_disabled"): .disabled
        case (404, _): .notFound
        case (413, "budget_receipt_quota_exceeded"): .draftQuota
        case (413, _): .tooLarge
        case (409, "budget_receipt_conflict"): .versionConflict
        case (409, "budget_receipt_tx_already_linked"): .alreadyLinked
        case (409, "already_submitted"): .alreadySubmitted
        case (409, "budget_receipt_stale_source"): .staleCandidate
        case (409, "device_token_limit_reached"): .deviceLimit
        case (409, let code?): .rejected(code)
        case (400, "budget_receipt_total_mismatch"): .totalMismatch
        case (400, "budget_auth_ambiguous"): .ambiguousAuth
        case (400, let code?): .rejected(code)
        case (400, nil): .rejected("invalid_request")
        case (429, _): .rateLimited
        case (503, _): .unavailable
        default: .api(.http(status))
        }
    }

    static func wrap(_ error: any Error) -> ReceiptError {
        if let receipt = error as? ReceiptError { return receipt }
        if let client = error as? ClientError {
            if let receipt = client.underlyingError as? ReceiptError { return receipt }
            if let status = client.response?.status.code, !(200..<300).contains(status) {
                return from(status: status, code: nil)
            }
        }
        return .api(APIError.wrap(error))
    }
}

/// v2 errors carry a nested code. The pinned OpenAPI spec uses a flat string.
struct BudgetErrorEnvelope: Decodable {
    let code: String

    init(from decoder: any Decoder) throws {
        enum Key: CodingKey { case error }
        struct Detail: Decodable { let code: String }
        let container = try decoder.container(keyedBy: Key.self)
        if let detail = try? container.decode(Detail.self, forKey: .error) {
            code = detail.code
        } else {
            code = try container.decode(String.self, forKey: .error)
        }
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
