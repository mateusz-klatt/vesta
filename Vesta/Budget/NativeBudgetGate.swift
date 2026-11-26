import Foundation

enum NativeBudgetGate {
    static func isEligible(enabled: Bool, features: ServerFeatures?, capabilities: Capabilities?) -> Bool {
        guard enabled, features?.supports(.budgetNativeRead) == true, let ownBudget = capabilities?.ownBudget else {
            return false
        }
        return ownBudget.canView && ownBudget.permissions.contains(.budgetView)
    }

    static func allowsDevice(_ token: StoredReceiptDeviceToken?, origin: URL, actor: String?) -> Bool {
        guard let actor, let token, token.provenance == .exchanged, token.actor == actor, token.owner == actor,
              token.deviceScope == .device, token.ownerKey?.isEmpty == false,
              OriginMatcher.matches(origin, token.server) else { return false }
        return token.issuedPermissions?.contains(Permission.budgetView.rawValue) == true
    }
}

/// An open budget view owns the permission and device binding that admitted it.
struct SessionBoundBudgetAPI: BudgetAPI {
    let api: any BudgetAPI
    let isCurrent: @MainActor @Sendable () -> Bool
    let onDenial: @MainActor @Sendable (BudgetError) -> Bool

    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly {
        try await read { try await api.monthlyBudget(period: period, currency: currency) }
    }

    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage {
        try await read {
            try await api.transactions(period: period, currency: currency, categoryID: categoryID, cursor: cursor, limit: limit)
        }
    }

    func status() async throws -> BudgetStatus {
        try await read { try await api.status() }
    }

    func overview(period: String, currency: String?) async throws -> BudgetOverview {
        try await read { try await api.overview(period: period, currency: currency) }
    }

    func categories() async throws -> [BudgetCategoryDefinition] {
        try await read { try await api.categories() }
    }

    func charts(period: String, currency: String?, history: Int) async throws -> BudgetChartSeries? {
        try await read { try await api.charts(period: period, currency: currency, history: history) }
    }

    private func read<Value: Sendable>(_ operation: () async throws -> Value) async throws -> Value {
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        let value: Value
        do {
            value = try await operation()
        } catch {
            try Task.checkCancellation()
            if let denial = error as? BudgetError, denial.isAccessDenial {
                guard await onDenial(denial) else { throw CancellationError() }
                throw error
            }
            guard await isCurrent() else { throw CancellationError() }
            throw error
        }
        guard await isCurrent() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    }
}
