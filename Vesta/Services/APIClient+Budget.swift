import OpenAPIRuntime

/// Device-token-authenticated, read-only budget analytics (gated by ``APIClient/budgetEnabled``).
extension APIClient: BudgetAPI {
    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly {
        try await read { client in
            let input = Operations.GetBudgetAnalyticsMonthlyBudget.Input(
                query: .init(period: period, currency: currency)
            )
            return try await BudgetMonthly(wire: client.getBudgetAnalyticsMonthlyBudget(input).ok.body.json)
        }
    }

    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage {
        try await read { client in
            let input = Operations.GetBudgetAnalyticsTransactions.Input(
                query: .init(
                    period: period, currency: currency, categoryId: categoryID,
                    limit: limit, cursor: cursor
                )
            )
            return try await BudgetTransactionPage(wire: client.getBudgetAnalyticsTransactions(input).ok.body.json)
        }
    }

    func status() async throws -> BudgetStatus {
        try await read { client in
            BudgetStatus(wire: try await client.getBudgetStatus(.init()).ok.body.json)
        }
    }

    func overview(period: String, currency: String?) async throws -> BudgetOverview {
        try await read { client in
            let input = Operations.GetBudgetAnalyticsOverview.Input(query: .init(period: period, currency: currency))
            return try await BudgetOverview(wire: client.getBudgetAnalyticsOverview(input).ok.body.json)
        }
    }

    func categories() async throws -> [BudgetCategoryDefinition] {
        try await read { client in
            let wire = try await client.getBudgetAnalyticsCategories(.init()).ok.body.json
            return wire.categories.map(BudgetCategoryDefinition.init(wire:))
        }
    }

    func charts(period: String, currency: String?, history: Int) async throws -> BudgetChartSeries? {
        guard history == 6 || history == 12 else { throw BudgetError.failed }
        return try await read { client in
            let input = Operations.GetBudgetAnalyticsMonthlyBudgetCharts.Input(query: .init(
                period: period, currency: currency, history: history == 12 ? ._12 : ._6
            ))
            let wire = try await client.getBudgetAnalyticsMonthlyBudgetCharts(input).ok.body.json
            return try wire.series.map(BudgetChartSeries.init(wire:))
        }
    }

    private func read<Value: Sendable>(_ operation: (Client) async throws -> Value) async throws -> Value {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        guard let scope = await currentBudgetScope() else { throw BudgetError.forbidden }
        let client = requestReceiptClient(scope: scope)
        do {
            try Task.checkCancellation()
            guard await isCurrentBudgetScope(scope) else { throw CancellationError() }
            let value = try await operation(client)
            try Task.checkCancellation()
            guard await isCurrentBudgetScope(scope) else { throw CancellationError() }
            return value
        } catch {
            if APIError.isCancellation(error) { throw CancellationError() }
            guard await isCurrentBudgetScope(scope) else { throw CancellationError() }
            throw BudgetError.wrap(error)
        }
    }
}
