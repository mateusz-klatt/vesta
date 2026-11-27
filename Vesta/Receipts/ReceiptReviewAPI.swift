import Foundation

enum ReceiptReviewGate {
    static let requiredPermissions: Set<Permission> = [.budgetReceiptsAdd, .budgetReceiptsView, .budgetReceiptsEdit]

    static func isEligible(enabled: Bool, capabilities: Capabilities?) -> Bool {
        guard enabled, let capabilities else { return false }
        return requiredPermissions.isSubset(of: permissions(capabilities, delegated: false))
            || requiredPermissions.isSubset(of: permissions(capabilities, delegated: true))
    }

    static func allowsDevice(
        _ token: StoredReceiptDeviceToken?, origin: URL, actor: String?, capabilities: Capabilities?
    ) -> Bool {
        guard let actor, let token, let capabilities, token.provenance == .exchanged, token.actor == actor,
              token.owner?.isEmpty == false, token.ownerKey?.isEmpty == false, token.deviceScope != nil,
              OriginMatcher.matches(origin, token.server),
              let issued = token.issuedPermissions else { return false }
        return requiredPermissions.isSubset(of: permissions(capabilities, delegated: token.owner != actor))
            && requiredPermissions.isSubset(of: issued.compactMap(Permission.init(rawValue:)))
    }

    static func allowsMatching(_ token: StoredReceiptDeviceToken?, capabilities: Capabilities?) -> Bool {
        guard let token, let actor = token.actor, let capabilities else { return false }
        return permissions(capabilities, delegated: token.owner != actor).contains(.budgetReceiptsMatch)
            && token.issuedPermissions?.contains(Permission.budgetReceiptsMatch.rawValue) == true
    }

    private static func permissions(_ capabilities: Capabilities, delegated: Bool) -> Set<Permission> {
        if delegated {
            guard let receipts = capabilities.delegatedReceipts, receipts.canUse else { return [] }
            return receipts.permissions
        }
        guard let budget = capabilities.ownBudget, budget.canUseReceipts else { return [] }
        return budget.permissions
    }
}

typealias ReceiptListPage = Components.Schemas.BudgetReceiptListResult
typealias ReceiptDetailResult = Components.Schemas.BudgetReceiptDetailResult

enum ReceiptReviewListFilter: Equatable, Sendable {
    case needsAction, imported
}

// Hestia binds the opaque cursor to the filters that produced it.
struct ReceiptReviewCursor: Sendable {
    let value: String
    let filter: ReceiptReviewListFilter
}

struct ReceiptReviewPage: Sendable {
    let receipts: [ReceiptReviewSummary]
    var nextCursor: ReceiptReviewCursor? = nil
}

protocol ReceiptReviewAPI: Sendable {
    func listReviewReceipts(
        cursor: ReceiptReviewCursor?, firstPageFilter: ReceiptReviewListFilter, scope: ReceiptSessionScope
    ) async throws -> ReceiptReviewPage
    func receiptDetail(id: String, scope: ReceiptSessionScope) async throws -> ReceiptDetailResult
    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope: ReceiptSessionScope) async throws -> ReceiptDetail
}

struct SessionBoundReceiptReviewAPI: ReceiptReviewAPI {
    let api: any ReceiptReviewAPI
    let scope: ReceiptSessionScope
    let isCurrent: @MainActor @Sendable () -> Bool
    let onDenial: @MainActor @Sendable (ReceiptError) -> Bool

    func listReviewReceipts(
        cursor: ReceiptReviewCursor?, firstPageFilter: ReceiptReviewListFilter, scope requested: ReceiptSessionScope
    ) async throws -> ReceiptReviewPage {
        try await run(requested) {
            try await api.listReviewReceipts(cursor: cursor, firstPageFilter: firstPageFilter, scope: scope)
        }
    }

    func receiptDetail(id: String, scope requested: ReceiptSessionScope) async throws -> ReceiptDetailResult {
        try await run(requested) { try await api.receiptDetail(id: id, scope: scope) }
    }

    func confirmImportedReceipt(_ request: ReceiptConfirmRequest, scope requested: ReceiptSessionScope) async throws -> ReceiptDetail {
        try await run(requested) { try await api.confirmImportedReceipt(request, scope: scope) }
    }

    private func run<Value: Sendable>(
        _ requested: ReceiptSessionScope,
        _ operation: () async throws -> Value
    ) async throws -> Value {
        guard requested == scope, await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        do {
            let value = try await operation()
            try Task.checkCancellation()
            guard await isCurrent() else { throw CancellationError() }
            return value
        } catch {
            if APIError.isCancellation(error) { throw CancellationError() }
            guard await isCurrent() else { throw CancellationError() }
            let error = ReceiptError.wrap(error)
            if error.isAccessDenial {
                guard await onDenial(error) else { throw CancellationError() }
            }
            throw error
        }
    }
}

extension ReceiptError {
    var isAccessDenial: Bool {
        switch self {
        case .forbidden, .pairAgain, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken: true
        case .api(.unauthorized): true
        default: false
        }
    }

    var reviewCode: String {
        switch self {
        case .photoUnavailable: "photo_unavailable"
        case .noReadableText: "no_readable_text"
        case .disabled: "budget_receipts_disabled"
        case .notFound: "not_found"
        case .forbidden: "forbidden"
        case .pairAgain: "pair_again"
        case .expiredDeviceToken: "device_token_expired"
        case .revokedDeviceToken: "device_token_revoked"
        case .invalidDeviceToken: "device_token_invalid"
        case .ambiguousAuth: "budget_auth_ambiguous"
        case .rateLimited: "rate_limited"
        case .draftQuota: "budget_receipt_quota_exceeded"
        case .tooLarge: "too_large"
        case .versionConflict: "budget_receipt_conflict"
        case .alreadyLinked: "budget_receipt_tx_already_linked"
        case .alreadySubmitted: "already_submitted"
        case .staleCandidate: "budget_receipt_stale_source"
        case .invalidTotal: "incomplete_receipt"
        case .totalMismatch: "budget_receipt_total_mismatch"
        case .redactedLinesEditBlocked: "budget_receipt_redacted_lines_edit_blocked"
        case .deviceLimit: "device_token_limit_reached"
        case .unsupportedContractVersion: "budget_receipt_contract_version_invalid"
        case .rejected(let code): code
        case .unavailable: "unavailable"
        case .api(.unauthorized): "unauthorized"
        case .api(let error): error.technical ?? "request_failed"
        }
    }
}
