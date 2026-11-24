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
        guard !isCleared else { return }
        await reload(keepContent: false)
    }

    func refresh() async {
        guard !isCleared, !isDenied else { return }
        await reload(keepContent: true)
    }

    func previousMonth() async {
        guard !isCleared, !isDenied else { return }
        await moveMonth(by: -1)
    }

    func nextMonth() async {
        guard !isCleared, !isDenied, canGoNext else { return }
        await moveMonth(by: 1)
    }

    func selectCurrency(_ value: String) async {
        guard !isCleared, !isDenied, value != currency, availableCurrencies.contains(value) else { return }
        currency = value
        await reload(keepContent: false)
    }

    func selectCategory(_ value: String?) async {
        guard !isCleared, !isDenied, value != categoryID else { return }
        categoryID = value
        transactions = []
        filteredTotal = 0
        nextCursor = nil
        activeQuery = nil
        await reload(keepContent: true)
    }

    func loadMore() async {
        guard !isCleared, !isDenied, !isLoading, !isLoadingMore, state == .loaded,
              let cursor = nextCursor, let query = activeQuery else { return }
        await runTask { [weak self] requestGeneration in
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
        await runTask { [weak self] requestGeneration in
            await self?.performReload(keepContent: keepContent, requestGeneration: requestGeneration)
        }
    }

    private func runTask(_ work: @escaping @MainActor (Int) async -> Void) async {
        guard !isCleared else { return }
        cancelWork()
        let requestGeneration = generation
        let task = Task { @MainActor in
            await work(requestGeneration)
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

    private func performReload(keepContent: Bool, requestGeneration: Int) async {
        guard !isCleared, requestGeneration == generation else { return }
        isLoading = true
        isRefreshing = keepContent && overview != nil
        isLoadingMore = false
        if !keepContent {
            overview = nil
            transactions = []
            filteredTotal = 0
            nextCursor = nil
            activeQuery = nil
            dataAsOf = nil
            availableCurrencies = []
            state = .loading
            failure = nil
        }
        let requestedPeriod = period
        let requestedCurrency = currency
        let requestedCategory = categoryID
        do {
            let monthlyResult = try await api.monthlyBudget(period: requestedPeriod, currency: requestedCurrency)
            guard !isCleared, requestGeneration == generation else { return }
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
            guard !isCleared, requestGeneration == generation else { return }
            if let currentMonth = Self.validPeriod(monthlyResult.currentMonth) {
                serverCurrentMonth = currentMonth
            }
            if let resolvedDate = Self.date(forPeriod: resolvedPeriod) {
                monthDate = resolvedDate
            }
            overview = monthlyResult
            currency = resolvedCurrency
            availableCurrencies = monthlyResult.availableCurrencies
            transactions = pageResult.transactions
            filteredTotal = pageResult.filteredTotal
            nextCursor = pageResult.nextCursor
            activeQuery = query
            dataAsOf = monthlyResult.ledgerAsOf
            state = .loaded
            failure = nil
            isLoading = false
            isRefreshing = false
        } catch {
            guard !isCleared, requestGeneration == generation else { return }
            isLoading = false
            isRefreshing = false
            if Self.isCancellation(error) { return }
            publish(BudgetError.wrap(error))
        }
    }

    private func performLoadMore(cursor: String, query: TransactionQuery, requestGeneration: Int) async {
        guard !isCleared, requestGeneration == generation else { return }
        isLoadingMore = true
        do {
            let page = try await api.transactions(
                period: query.period, currency: query.currency, categoryID: query.categoryID,
                cursor: cursor, limit: query.limit
            )
            guard !isCleared, requestGeneration == generation else { return }
            var ids = Set(transactions.map(\.id))
            transactions.append(contentsOf: page.transactions.filter { ids.insert($0.id).inserted })
            filteredTotal = page.filteredTotal
            nextCursor = page.nextCursor
            isLoadingMore = false
        } catch {
            guard !isCleared, requestGeneration == generation else { return }
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
            // Snapshot changed between pages; restart from page 0 with the exact same filters.
            nextCursor = nil
            do {
                let restarted = try await api.transactions(
                    period: query.period, currency: query.currency, categoryID: query.categoryID,
                    cursor: nil, limit: query.limit
                )
                guard !isCleared, requestGeneration == generation else { return }
                transactions = restarted.transactions
                filteredTotal = restarted.filteredTotal
                nextCursor = restarted.nextCursor
                activeQuery = query
                isLoadingMore = false
            } catch {
                guard !isCleared, requestGeneration == generation else { return }
                isLoadingMore = false
                if Self.isCancellation(error) { return }
                publish(BudgetError.wrap(error))
            }
        }
    }

    private func publish(_ error: BudgetError) {
        failure = error
        switch error {
        case .unauthorized:
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
