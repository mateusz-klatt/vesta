import Foundation
import Observation
import OpenAPIRuntime

@MainActor
@Observable
final class BudgetStore {
    enum State: Equatable {
        case loading
        case loaded
        case unavailable
        case unauthorized
        case forbidden
        case failed
    }

    private struct TransactionQuery: Equatable {
        let period: String
        let currency: String
        let categoryID: String?
        let limit: Int
    }

    private static let pageLimit = 50
    static let warsawTimeZone = TimeZone(identifier: "Europe/Warsaw") ?? TimeZone(secondsFromGMT: 3600)!
    static let warsawCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = warsawTimeZone
        return calendar
    }()

    private let api: any BudgetAPI
    private let now: Date
    private var generation = 0
    private var activeTask: Task<Void, Never>?
    private var activeQuery: TransactionQuery?

    private(set) var isCleared = false
    private(set) var monthDate: Date
    private(set) var serverCurrentMonth: String?
    private(set) var currency: String?
    private(set) var availableCurrencies: [String] = []
    private(set) var categoryID: String?
    private(set) var overview: BudgetMonthly?
    private(set) var analyticsOverview: BudgetOverview?
    private(set) var categoryCatalog: [BudgetCategoryDefinition] = []
    private(set) var chartSeries: BudgetChartSeries?
    private(set) var transactions: [BudgetTransaction] = []
    private(set) var filteredTotal = 0
    private(set) var nextCursor: String?
    private(set) var dataAsOf: Date?
    private(set) var state: State = .loading
    private(set) var failure: BudgetError?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false

    var isDenied: Bool { state == .forbidden || state == .unauthorized }
    private var isTerminal: Bool { isCleared || isDenied }
    var period: String { Self.period(for: monthDate) }
    var maxPeriod: String { serverCurrentMonth ?? Self.period(for: now) }
    var canGoNext: Bool { period < maxPeriod }

    init(api: any BudgetAPI, now: Date = Date()) {
        self.api = api
        self.now = now
        monthDate = Self.startOfMonth(for: now) ?? now
    }

    static func monthTitle(for date: Date, locale: Locale) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year().locale(locale)
        style.calendar = warsawCalendar
        style.timeZone = warsawTimeZone
        return date.formatted(style)
    }

    func load() async {
        guard !isTerminal else { return }
        await reload(keepContent: false)
    }

    func refresh() async {
        guard !isTerminal else { return }
        await reload(keepContent: true)
    }

    func previousMonth() async {
        guard !isTerminal else { return }
        await moveMonth(by: -1)
    }

    func nextMonth() async {
        guard !isTerminal, canGoNext else { return }
        await moveMonth(by: 1)
    }

    func selectCurrency(_ value: String) async {
        guard !isTerminal, value != currency, availableCurrencies.contains(value) else { return }
        currency = value
        await reload(keepContent: false)
    }

    func selectCategory(_ value: String?) async {
        guard !isTerminal, value != categoryID else { return }
        categoryID = value
        transactions = []
        filteredTotal = 0
        await reload(keepContent: true)
    }

    func loadMore() async {
        guard !isTerminal, !isLoading, !isLoadingMore, state == .loaded,
              let cursor = nextCursor, let query = activeQuery else { return }
        cancelWork()
        let requestGeneration = generation
        isLoadingMore = true
        await runReservedTask(generation: requestGeneration) { [weak self] in
            await self?.performLoadMore(cursor: cursor, query: query, requestGeneration: requestGeneration)
        }
    }

    func clear() {
        isCleared = true
        cancelWork()
        wipeData()
        failure = nil
        state = .loading
        isLoading = false
        isRefreshing = false
        isLoadingMore = false
    }

    private func moveMonth(by offset: Int) async {
        guard let moved = Self.warsawCalendar.date(byAdding: .month, value: offset, to: monthDate) else { return }
        if offset > 0, Self.period(for: moved) > maxPeriod { return }
        monthDate = moved
        await reload(keepContent: false)
    }

    private func reload(keepContent: Bool) async {
        guard !isTerminal else { return }
        // Reserve the reload synchronously before yielding so a queued loadMore()
        // cannot observe the old cursor or cancel this reload.
        cancelWork()
        let requestGeneration = generation
        isLoading = true
        isRefreshing = keepContent && overview != nil
        isLoadingMore = false
        nextCursor = nil
        activeQuery = nil
        if !keepContent {
            overview = nil
            analyticsOverview = nil
            categoryCatalog = []
            chartSeries = nil
            transactions = []
            filteredTotal = 0
            dataAsOf = nil
            availableCurrencies = []
            state = .loading
            failure = nil
        }
        await runReservedTask(generation: requestGeneration) { [weak self] in
            await self?.performReload(requestGeneration: requestGeneration)
        }
    }

    private func runReservedTask(
        generation requestGeneration: Int,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        guard !isTerminal, requestGeneration == generation else { return }
        let task = Task { @MainActor in
            await work()
        }
        activeTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == requestGeneration {
            activeTask = nil
        }
    }

    private func cancelWork() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
    }

    private func wipeData() {
        overview = nil
        analyticsOverview = nil
        categoryCatalog = []
        chartSeries = nil
        transactions = []
        filteredTotal = 0
        nextCursor = nil
        activeQuery = nil
        dataAsOf = nil
        availableCurrencies = []
        currency = nil
        categoryID = nil
        serverCurrentMonth = nil
    }

    private func performReload(requestGeneration: Int) async {
        guard !isTerminal, requestGeneration == generation else { return }
        let requestedPeriod = period
        let requestedCurrency = currency
        let requestedCategory = categoryID
        do {
            let monthlyResult = try await api.monthlyBudget(period: requestedPeriod, currency: requestedCurrency)
            guard !isTerminal, requestGeneration == generation else { return }
            let resolvedPeriod = Self.validPeriod(monthlyResult.period) ?? requestedPeriod
            let resolvedCurrency = monthlyResult.currency
            let query = TransactionQuery(
                period: resolvedPeriod, currency: resolvedCurrency,
                categoryID: requestedCategory, limit: Self.pageLimit
            )
            let pageResult = try await api.transactions(
                period: query.period, currency: query.currency,
                categoryID: query.categoryID, cursor: nil, limit: query.limit
            )
            guard !isTerminal, requestGeneration == generation else { return }
            let native = try await loadNativeAnalytics(period: query.period, currency: query.currency)
            guard !isTerminal, requestGeneration == generation else { return }
            analyticsOverview = native.overview
            categoryCatalog = native.categories
            chartSeries = native.charts
            applyLoaded(monthly: monthlyResult, page: pageResult, resolvedPeriod: resolvedPeriod, query: query)
            isLoading = false
            isRefreshing = false
        } catch {
            guard !isTerminal, requestGeneration == generation else { return }
            isLoading = false
            isRefreshing = false
            if Self.isCancellation(error) { return }
            publish(BudgetError.wrap(error))
        }
    }

    private func loadNativeAnalytics(
        period: String,
        currency: String
    ) async throws -> (overview: BudgetOverview, categories: [BudgetCategoryDefinition], charts: BudgetChartSeries?) {
        async let overviewResult = api.overview(period: period, currency: currency)
        async let categoryResult = api.categories()
        async let chartResult = api.charts(period: period, currency: currency, history: 6)
        return try await (overviewResult, categoryResult, chartResult)
    }

    private func performLoadMore(cursor: String, query: TransactionQuery, requestGeneration: Int) async {
        guard !isTerminal, requestGeneration == generation else { return }
        do {
            let page = try await api.transactions(
                period: query.period, currency: query.currency, categoryID: query.categoryID,
                cursor: cursor, limit: query.limit
            )
            guard !isTerminal, requestGeneration == generation else { return }
            var ids = Set(transactions.map(\.id))
            transactions.append(contentsOf: page.transactions.filter { ids.insert($0.id).inserted })
            filteredTotal = page.filteredTotal
            nextCursor = page.nextCursor
            isLoadingMore = false
        } catch {
            guard !isTerminal, requestGeneration == generation else { return }
            if Self.isCancellation(error) {
                isLoadingMore = false
                return
            }
            let wrapped = BudgetError.wrap(error)
            guard wrapped == .staleCursor else {
                isLoadingMore = false
                publish(wrapped)
                return
            }
            // Snapshot changed between pages; refresh overview together with page 0
            // using the exact same filters so summary, rows and freshness stay coherent.
            nextCursor = nil
            do {
                let monthlyResult = try await api.monthlyBudget(period: query.period, currency: query.currency)
                guard !isTerminal, requestGeneration == generation else { return }
                let resolvedPeriod = Self.validPeriod(monthlyResult.period) ?? query.period
                let refreshedQuery = TransactionQuery(
                    period: resolvedPeriod, currency: monthlyResult.currency,
                    categoryID: query.categoryID, limit: query.limit
                )
                let restarted = try await api.transactions(
                    period: refreshedQuery.period, currency: refreshedQuery.currency,
                    categoryID: refreshedQuery.categoryID, cursor: nil, limit: refreshedQuery.limit
                )
                guard !isTerminal, requestGeneration == generation else { return }
                let native = try await loadNativeAnalytics(period: refreshedQuery.period, currency: refreshedQuery.currency)
                guard !isTerminal, requestGeneration == generation else { return }
                analyticsOverview = native.overview
                categoryCatalog = native.categories
                chartSeries = native.charts
                applyLoaded(monthly: monthlyResult, page: restarted, resolvedPeriod: resolvedPeriod, query: refreshedQuery)
                isLoadingMore = false
            } catch {
                guard !isTerminal, requestGeneration == generation else { return }
                isLoadingMore = false
                if Self.isCancellation(error) { return }
                publish(BudgetError.wrap(error))
            }
        }
    }

    private func applyLoaded(
        monthly: BudgetMonthly,
        page: BudgetTransactionPage,
        resolvedPeriod: String,
        query: TransactionQuery
    ) {
        if let currentMonth = Self.validPeriod(monthly.currentMonth) {
            serverCurrentMonth = currentMonth
        }
        if let resolvedDate = Self.date(forPeriod: resolvedPeriod) {
            monthDate = resolvedDate
        }
        overview = monthly
        currency = monthly.currency
        availableCurrencies = monthly.availableCurrencies
        transactions = page.transactions
        filteredTotal = page.filteredTotal
        nextCursor = page.nextCursor
        activeQuery = query
        dataAsOf = monthly.ledgerAsOf
        state = .loaded
        failure = nil
    }

    private func publish(_ error: BudgetError) {
        failure = error
        switch error {
        case .unauthorized, .expiredDeviceToken, .revokedDeviceToken, .invalidDeviceToken:
            cancelWork()
            wipeData()
            state = .unauthorized
        case .forbidden:
            cancelWork()
            wipeData()
            state = .forbidden
        case .unavailable:
            state = .unavailable
        case .staleCursor, .failed:
            state = .failed
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if let client = error as? ClientError { return isCancellation(client.underlyingError) }
        return false
    }

    private static func startOfMonth(for date: Date) -> Date? {
        let components = warsawCalendar.dateComponents([.year, .month], from: date)
        return warsawCalendar.date(from: components)
    }

    private static func validPeriod(_ raw: String?) -> String? {
        guard let raw, date(forPeriod: raw) != nil else { return nil }
        return raw
    }

    private static func date(forPeriod period: String) -> Date? {
        let parts = period.split(separator: "-")
        guard parts.count == 2,
              parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]),
              (1...12).contains(month)
        else { return nil }
        var components = DateComponents()
        components.calendar = warsawCalendar
        components.timeZone = warsawTimeZone
        components.year = year
        components.month = month
        components.day = 1
        return warsawCalendar.date(from: components)
    }

    private static func period(for date: Date) -> String {
        let components = warsawCalendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
}
