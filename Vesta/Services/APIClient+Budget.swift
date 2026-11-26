/// Device-token-authenticated, read-only budget analytics (gated by ``APIClient/budgetEnabled``).
extension APIClient: BudgetAPI {
    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        let client = requestClient()
        do {
            let input = Operations.GetBudgetAnalyticsMonthlyBudget.Input(
                query: .init(period: period, currency: currency)
            )
            return try await BudgetMonthly(wire: client.getBudgetAnalyticsMonthlyBudget(input).ok.body.json)
        } catch { throw BudgetError.wrap(error) }
    }

    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        let client = requestClient()
        do {
            let input = Operations.GetBudgetAnalyticsTransactions.Input(
                query: .init(
                    period: period, currency: currency, categoryId: categoryID,
                    limit: limit, cursor: cursor
                )
            )
            return try await BudgetTransactionPage(wire: client.getBudgetAnalyticsTransactions(input).ok.body.json)
        } catch { throw BudgetError.wrap(error) }
    }

    func status() async throws -> BudgetStatus {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        let client = requestClient()
        do {
            return BudgetStatus(wire: try await client.getBudgetStatus(.init()).ok.body.json)
        } catch { throw BudgetError.wrap(error) }
    }

    func overview(period: String, currency: String?) async throws -> BudgetOverview {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        let client = requestClient()
        do {
            let input = Operations.GetBudgetAnalyticsOverview.Input(query: .init(period: period, currency: currency))
            return try await BudgetOverview(wire: client.getBudgetAnalyticsOverview(input).ok.body.json)
        } catch { throw BudgetError.wrap(error) }
    }

    func categories() async throws -> [BudgetCategoryDefinition] {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        let client = requestClient()
        do {
            let wire = try await client.getBudgetAnalyticsCategories(.init()).ok.body.json
            return wire.categories.map(BudgetCategoryDefinition.init(wire:))
        } catch { throw BudgetError.wrap(error) }
    }

    func charts(period: String, currency: String?, history: Int) async throws -> BudgetChartSeries? {
        guard budgetEnabled() else { throw BudgetError.forbidden }
        guard history == 6 || history == 12 else { throw BudgetError.failed }
        let client = requestClient()
        do {
            let input = Operations.GetBudgetAnalyticsMonthlyBudgetCharts.Input(query: .init(
                period: period, currency: currency, history: history == 12 ? ._12 : ._6
            ))
            let wire = try await client.getBudgetAnalyticsMonthlyBudgetCharts(input).ok.body.json
            return try wire.series.map(BudgetChartSeries.init(wire:))
        } catch { throw BudgetError.wrap(error) }
    }
}
