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
}
