import Foundation
import Observation

@MainActor
@Observable
final class BudgetStore {
    enum State: Equatable {
        case loading
        case loaded
        case unavailable
        case forbidden
        case failed
    }

    private static let pageLimit = 50

    private let api: any BudgetAPI
    private let calendar: Calendar
    private let now: Date
    private var generation = 0

    private(set) var monthDate: Date
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

    var period: String { Self.period(for: monthDate, calendar: calendar) }
    var canGoNext: Bool { period < Self.period(for: now, calendar: calendar) }

    init(api: any BudgetAPI, now: Date = Date(), calendar: Calendar = .current) {
        self.api = api
        self.now = now
        self.calendar = calendar
        monthDate = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    func load() async {
        await reload(keepContent: false)
    }

    func refresh() async {
        await reload(keepContent: true)
    }

    func previousMonth() async {
        await moveMonth(by: -1)
    }

    func nextMonth() async {
        guard canGoNext else { return }
        await moveMonth(by: 1)
    }

    func selectCurrency(_ value: String) async {
        guard value != currency, availableCurrencies.contains(value) else { return }
        currency = value
        await reload(keepContent: false)
    }

    func selectCategory(_ value: String?) async {
        guard value != categoryID else { return }
        categoryID = value
        transactions = []
        filteredTotal = 0
        nextCursor = nil
        await reload(keepContent: true)
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, state == .loaded, let cursor = nextCursor else { return }
        generation += 1
        let requestGeneration = generation
        isLoadingMore = true
        do {
            let page = try await api.transactions(
                period: period, currency: currency, categoryID: categoryID,
                cursor: cursor, limit: Self.pageLimit
            )
            guard requestGeneration == generation else { return }
            var ids = Set(transactions.map(\.id))
            transactions.append(contentsOf: page.transactions.filter { ids.insert($0.id).inserted })
            filteredTotal = page.filteredTotal
            nextCursor = page.nextCursor
            isLoadingMore = false
        } catch {
            guard requestGeneration == generation else { return }
            isLoadingMore = false
            publish(BudgetError.wrap(error))
        }
    }

    func clear() {
        generation += 1
        overview = nil
        transactions = []
        filteredTotal = 0
        nextCursor = nil
        dataAsOf = nil
        availableCurrencies = []
        currency = nil
        categoryID = nil
        failure = nil
        state = .loading
        isLoading = false
        isRefreshing = false
        isLoadingMore = false
    }

    private func moveMonth(by offset: Int) async {
        guard let moved = calendar.date(byAdding: .month, value: offset, to: monthDate) else { return }
        monthDate = moved
        await reload(keepContent: false)
    }

    private func reload(keepContent: Bool) async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        isRefreshing = keepContent && overview != nil
        isLoadingMore = false
        if !keepContent {
            overview = nil
            transactions = []
            filteredTotal = 0
            nextCursor = nil
            dataAsOf = nil
            availableCurrencies = []
            state = .loading
            failure = nil
        }
        let requestedPeriod = period
        let requestedCurrency = currency
        let requestedCategory = categoryID
        do {
            async let monthly = api.monthlyBudget(period: requestedPeriod, currency: requestedCurrency)
            async let page = api.transactions(
                period: requestedPeriod, currency: requestedCurrency,
                categoryID: requestedCategory, cursor: nil, limit: Self.pageLimit
            )
            async let freshness = api.status()
            let (monthlyResult, pageResult, freshnessResult) = try await (monthly, page, freshness)
            guard requestGeneration == generation else { return }
            overview = monthlyResult
            currency = monthlyResult.currency
            availableCurrencies = monthlyResult.availableCurrencies
            transactions = pageResult.transactions
            filteredTotal = pageResult.filteredTotal
            nextCursor = pageResult.nextCursor
            dataAsOf = freshnessResult.dataAsOf
            state = .loaded
            failure = nil
            isLoading = false
            isRefreshing = false
        } catch {
            guard requestGeneration == generation else { return }
            isLoading = false
            isRefreshing = false
            publish(BudgetError.wrap(error))
        }
    }

    private func publish(_ error: BudgetError) {
        failure = error
        switch error {
        case .forbidden: state = .forbidden
        case .unavailable: state = .unavailable
        case .unauthorized, .failed: state = .failed
        }
    }

    private static func period(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
}
