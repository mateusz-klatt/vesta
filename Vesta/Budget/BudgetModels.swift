import Foundation

struct BudgetSummary: Equatable, Sendable {
    let startBudget: Decimal
    let spent: Decimal
    let remaining: Decimal
}

struct BudgetPace: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case historical
        case noBudget
        case alreadyReached
        case noPositivePace
        case runsOut
        case withinBudget
    }

    let status: Status
    let budget: Decimal
    let projectedMonthSpend: Decimal?
    let exhaustionDay: Int?
}

struct BudgetCategoryLimit: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case within
        case approaching
        case atLimit
        case exceeded
    }

    let monthlyLimit: Decimal
    let remaining: Decimal
    let overBy: Decimal
    let percentUsedFloor: Decimal
    let warningPercent: Int
    let status: Status

    var isOver: Bool { status == .exceeded }
}

struct BudgetCategory: Identifiable, Hashable, Sendable {
    let categoryID: String?
    let name: String?
    let isOneOff: Bool
    let oneOffKey: String?
    let expenses: Decimal
    let refunds: Decimal
    let netSpending: Decimal
    let limit: BudgetCategoryLimit?

    var id: String {
        if let oneOffKey { return oneOffKey }
        if isOneOff { return "one-off:\(categoryID ?? "uncategorised"):\(name ?? "")" }
        return categoryID ?? "uncategorised"
    }

    init(
        categoryID: String?,
        name: String?,
        isOneOff: Bool = false,
        oneOffKey: String? = nil,
        expenses: Decimal,
        refunds: Decimal,
        netSpending: Decimal,
        limit: BudgetCategoryLimit?
    ) {
        self.categoryID = categoryID
        self.name = name
        self.isOneOff = isOneOff
        self.oneOffKey = oneOffKey
        self.expenses = expenses
        self.refunds = refunds
        self.netSpending = netSpending
        self.limit = limit
    }
}

struct BudgetMonthly: Equatable, Sendable {
    let period: String
    let currentMonth: String?
    let currency: String
    let availableCurrencies: [String]
    let ledgerAsOf: Date?
    let summary: BudgetSummary?
    let pace: BudgetPace?
    let categories: [BudgetCategory]

    init(
        period: String,
        currentMonth: String? = nil,
        currency: String,
        availableCurrencies: [String],
        ledgerAsOf: Date? = nil,
        summary: BudgetSummary?,
        pace: BudgetPace?,
        categories: [BudgetCategory]
    ) {
        self.period = period
        self.currentMonth = currentMonth
        self.currency = currency
        self.availableCurrencies = availableCurrencies
        self.ledgerAsOf = ledgerAsOf
        self.summary = summary
        self.pace = pace
        self.categories = categories
    }
}

struct BudgetTransaction: Identifiable, Equatable, Sendable {
    let id: String
    let accountID: String
    let entryReference: String
    let amount: Decimal
    let isCredit: Bool
    let currency: String
    let bookingDate: String?
    let payee: String?
    let details: String?
    let categoryID: String?
    let kind: String

    var signedAmount: Decimal { isCredit ? amount : -amount }
}

struct BudgetTransactionPage: Equatable, Sendable {
    let transactions: [BudgetTransaction]
    let nextCursor: String?
    let filteredTotal: Int
}

struct BudgetStatus: Equatable, Sendable {
    let dataAsOf: Date?
}

private enum BudgetWire {
    static let posix = Locale(identifier: "en_US_POSIX")

    static func decimal(_ raw: String) throws -> Decimal {
        guard let value = Decimal(string: raw, locale: posix) else { throw BudgetError.failed }
        return value
    }

    static func ratio(_ raw: Components.Schemas.BudgetAnalyticsMonthlyBudgetRatio?) throws -> Decimal? {
        guard let raw else { return nil }
        return try decimal(raw.numerator) / Decimal(raw.denominator)
    }
}

extension BudgetSummary {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetSummary) throws {
        startBudget = try BudgetWire.decimal(wire.startBudget)
        spent = try BudgetWire.decimal(wire.spent)
        remaining = try BudgetWire.decimal(wire.remaining)
    }
}

extension BudgetPace {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetPace) throws {
        status = switch wire.status {
        case .historical: .historical
        case .noBudget: .noBudget
        case .alreadyReached: .alreadyReached
        case .noPositivePace: .noPositivePace
        case .runsOut: .runsOut
        case .withinBudget: .withinBudget
        }
        budget = try BudgetWire.decimal(wire.budget)
        projectedMonthSpend = try BudgetWire.ratio(wire.projectedMonthSpend)
        exhaustionDay = wire.exhaustionDay
    }
}

extension BudgetCategoryLimit {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetCategoryLimit) throws {
        monthlyLimit = try BudgetWire.decimal(wire.monthlyLimit)
        remaining = try BudgetWire.decimal(wire.remaining)
        overBy = try BudgetWire.decimal(wire.overBy)
        percentUsedFloor = try BudgetWire.decimal(wire.percentUsedFloor)
        warningPercent = wire.warningPercent
        status = switch wire.status {
        case .within: .within
        case .approaching: .approaching
        case .atLimit: .atLimit
        case .exceeded: .exceeded
        }
    }
}

extension BudgetCategory {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetCategorySpend) throws {
        categoryID = wire.categoryId
        name = wire.displayLabel ?? wire.displayName ?? wire.name
        isOneOff = (wire.oneOff ?? false) || wire.oneOffKey != nil
        oneOffKey = wire.oneOffKey
        expenses = try BudgetWire.decimal(wire.expenses)
        refunds = try BudgetWire.decimal(wire.refunds)
        netSpending = try BudgetWire.decimal(wire.netSpending)
        limit = try wire.limit.map(BudgetCategoryLimit.init(wire:))
    }
}

extension BudgetMonthly {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudget) throws {
        period = wire.period
        currentMonth = wire.currentMonth
        currency = wire.currency
        availableCurrencies = wire.availableCurrencies
        ledgerAsOf = wire.coverage.ledgerAsOf.map(Date.init(timeIntervalSince1970:))
        summary = try wire.summary.map(BudgetSummary.init(wire:))
        pace = try wire.pace.map(BudgetPace.init(wire:))
        categories = try wire.categorySpend.map(BudgetCategory.init(wire:))
    }
}

extension BudgetTransaction {
    init(wire: Components.Schemas.BudgetAnalyticsTransaction) throws {
        accountID = wire.accountId
        entryReference = wire.entryReference
        id = "\(wire.accountId)\u{1f}\(wire.entryReference)"
        amount = try BudgetWire.decimal(wire.amount)
        isCredit = wire.creditDebitIndicator == .crdt
        currency = wire.currency
        bookingDate = wire.bookingDate ?? wire.valueDate ?? wire.transactionDate
        payee = isCredit ? wire.metadata?.debtorName : wire.metadata?.creditorName
        let details = wire.remittanceInformation.filter { !$0.isEmpty }.joined(separator: " · ")
        self.details = details.isEmpty ? nil : details
        categoryID = wire.effective.categoryId
        kind = wire.effective.kind
    }
}

extension BudgetTransactionPage {
    init(wire: Components.Schemas.BudgetAnalyticsTransactions) throws {
        transactions = try wire.transactions.map(BudgetTransaction.init(wire:))
        nextCursor = wire.nextCursor
        filteredTotal = wire.filteredTotal
    }
}

extension BudgetStatus {
    init(wire: Components.Schemas.BudgetStatus) {
        let timestamps = wire.status.flatMap { connection in
            [connection.lastSuccess] + connection.accounts.flatMap { account in
                [account.lastSuccess, account.components.transactions.lastSuccess, account.components.balances.lastSuccess]
            }
        }
        dataAsOf = timestamps.compactMap { $0 }.max().map(Date.init(timeIntervalSince1970:))
    }
}
