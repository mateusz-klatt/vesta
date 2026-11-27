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
    let creditDebitIndicator: BudgetAnalyticsTransactionWire.CreditDebitIndicatorPayload
    let currency: String
    let bookingDate: String?
    let payee: String?
    let details: String?
    let categoryID: String?
    let kind: String
    let receipt: BudgetTransactionReceipt?

    var isCredit: Bool { creditDebitIndicator == .crdt }

    var signedAmount: Decimal? {
        switch creditDebitIndicator {
        case .crdt: amount
        case .dbit: -amount
        case .unknown: nil
        }
    }

    func formattedAmount(locale: Locale) -> String {
        let value = (signedAmount ?? abs(amount)).formatted(.currency(code: currency).locale(locale))
        return isCredit ? "+\(value)" : value
    }
}

struct BudgetTransactionReceipt: Equatable, Sendable {
    let shopName: String?
    let total: Decimal?
    let currency: String?
    let status: BudgetAnalyticsTransactionReceiptWire.Status

    init(wire: Components.Schemas.BudgetAnalyticsTransactionReceipt) {
        shopName = wire.shopName
        total = wire.total.flatMap { try? BudgetWire.decimal($0) }
        currency = wire.currency
        status = wire.status
    }
}

struct BudgetTransactionPage: Equatable, Sendable {
    let transactions: [BudgetTransaction]
    let nextCursor: String?
    let filteredTotal: Int
}

struct BudgetStatus: Equatable, Sendable {
    let dataAsOf: Date?
}

struct BudgetCurrencyTotal: Equatable, Sendable {
    let currency: String
    let expenses: Decimal
    let refunds: Decimal
    let netSpending: Decimal
    let income: Decimal
}

struct BudgetOverviewCategory: Identifiable, Equatable, Sendable {
    let categoryID: String?
    let name: String?
    let isOneOff: Bool
    let oneOffKey: String?
    let currency: String
    let expenses: Decimal
    let refunds: Decimal
    let netSpending: Decimal
    let archived: Bool

    var id: String {
        if let oneOffKey { return oneOffKey }
        if isOneOff { return "one-off:\(categoryID ?? "uncategorised"):\(name ?? ""):\(currency)" }
        return "\(categoryID ?? "uncategorised"):\(currency)"
    }
}

struct BudgetOverview: Equatable, Sendable {
    let period: String
    let currencies: [BudgetCurrencyTotal]
    let categories: [BudgetOverviewCategory]
}

struct BudgetCategoryDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let displayName: String?
    let parentID: String?
    let colorHue: Int?
    let archived: Bool
    let translations: [String: String]

    var title: String { displayName ?? name }
}

struct BudgetChartPoint: Identifiable, Equatable, Sendable {
    let date: String
    let cumulativeSpent: Decimal

    var id: String { date }
}

struct BudgetChartMonth: Identifiable, Equatable, Sendable {
    let period: String
    let startBudget: Decimal
    let spent: Decimal

    var id: String { period }
}

struct BudgetChartSeries: Equatable, Sendable {
    let daily: [BudgetChartPoint]
    let months: [BudgetChartMonth]
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
        isOneOff = wire.oneOff || wire.oneOffKey != nil
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
        creditDebitIndicator = wire.creditDebitIndicator
        currency = wire.currency
        bookingDate = wire.bookingDate ?? wire.valueDate ?? wire.transactionDate
        payee = switch creditDebitIndicator {
        case .crdt: wire.metadata?.debtorName
        case .dbit: wire.metadata?.creditorName
        case .unknown: wire.metadata?.creditorName ?? wire.metadata?.debtorName
        }
        let details = wire.remittanceInformation.filter { !$0.isEmpty }.joined(separator: " · ")
        self.details = details.isEmpty ? nil : details
        categoryID = wire.effective.categoryId
        kind = wire.effective.kind
        receipt = wire.receipt.map(BudgetTransactionReceipt.init(wire:))
    }
}

// Keep the optional anyOf-null receipt alongside the existing generated field types.
struct BudgetAnalyticsTransactionWire: Codable, Hashable, Sendable {
    enum CreditDebitIndicatorPayload: String, Codable, Hashable, Sendable, CaseIterable, APIResponseStringEnum {
        case crdt = "CRDT", dbit = "DBIT", unknown
    }

    enum StatusPayload: String, Codable, Hashable, Sendable, CaseIterable, APIResponseStringEnum {
        case book = "BOOK", unknown
    }

    let accountId: String
    let amount: String
    let annotation: Components.Schemas.BudgetAnalyticsAnnotation
    let apiObservedAt: Double?
    let bookingDate: String?
    let counterpartyAccount: String?
    let counterpartyAccountKey: String?
    let creditDebitIndicator: CreditDebitIndicatorPayload
    let currency: String
    let effective: Components.Schemas.BudgetAnalyticsEffective
    let entryReference: String
    let fingerprint: String
    let metadata: Components.Schemas.BudgetAnalyticsMetadata?
    let observedAt: Double
    let receipt: Components.Schemas.BudgetAnalyticsTransactionReceipt?
    let remittanceInformation: [String]
    let source: String
    let status: StatusPayload
    let transactionDate: String?
    let transfer: Components.Schemas.BudgetAnalyticsTransactionTransfer
    let transferFingerprint: String
    let valueDate: String?

    private enum CodingKeys: String, CodingKey {
        case accountId = "account_id", amount, annotation, apiObservedAt = "api_observed_at"
        case bookingDate = "booking_date", counterpartyAccount = "counterparty_account"
        case counterpartyAccountKey = "counterparty_account_key", creditDebitIndicator = "credit_debit_indicator"
        case currency, effective, entryReference = "entry_reference", fingerprint, metadata, observedAt = "observed_at"
        case receipt, remittanceInformation = "remittance_information", source, status
        case transactionDate = "transaction_date", transfer, transferFingerprint = "transfer_fingerprint", valueDate = "value_date"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try values.decode(String.self, forKey: .accountId)
        amount = try values.decode(String.self, forKey: .amount)
        annotation = try values.decode(Components.Schemas.BudgetAnalyticsAnnotation.self, forKey: .annotation)
        apiObservedAt = try values.decodeIfPresent(Double.self, forKey: .apiObservedAt)
        bookingDate = try values.decodeIfPresent(String.self, forKey: .bookingDate)
        counterpartyAccount = try values.decodeIfPresent(String.self, forKey: .counterpartyAccount)
        counterpartyAccountKey = try values.decodeIfPresent(String.self, forKey: .counterpartyAccountKey)
        creditDebitIndicator = try values.decode(CreditDebitIndicatorPayload.self, forKey: .creditDebitIndicator)
        currency = try values.decode(String.self, forKey: .currency)
        effective = try values.decode(Components.Schemas.BudgetAnalyticsEffective.self, forKey: .effective)
        entryReference = try values.decode(String.self, forKey: .entryReference)
        fingerprint = try values.decode(String.self, forKey: .fingerprint)
        metadata = try values.decodeIfPresent(Components.Schemas.BudgetAnalyticsMetadata.self, forKey: .metadata)
        observedAt = try values.decode(Double.self, forKey: .observedAt)
        // A malformed receipt summary only affects the chip on this row.
        receipt = try? values.decodeIfPresent(Components.Schemas.BudgetAnalyticsTransactionReceipt.self, forKey: .receipt)
        remittanceInformation = try values.decode([String].self, forKey: .remittanceInformation)
        source = try values.decode(String.self, forKey: .source)
        status = try values.decode(StatusPayload.self, forKey: .status)
        transactionDate = try values.decodeIfPresent(String.self, forKey: .transactionDate)
        transfer = try values.decode(Components.Schemas.BudgetAnalyticsTransactionTransfer.self, forKey: .transfer)
        transferFingerprint = try values.decode(String.self, forKey: .transferFingerprint)
        valueDate = try values.decodeIfPresent(String.self, forKey: .valueDate)
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

extension BudgetCurrencyTotal {
    init(wire: Components.Schemas.BudgetAnalyticsCurrency) throws {
        currency = wire.currency
        expenses = try BudgetWire.decimal(wire.expenses)
        refunds = try BudgetWire.decimal(wire.refunds)
        netSpending = try BudgetWire.decimal(wire.netSpending)
        income = try BudgetWire.decimal(wire.income)
    }
}

extension BudgetOverviewCategory {
    init(wire: Components.Schemas.BudgetAnalyticsCategoryTotal) throws {
        categoryID = wire.categoryId
        name = wire.displayLabel ?? wire.displayName ?? wire.name
        isOneOff = wire.oneOff || wire.oneOffKey != nil
        oneOffKey = wire.oneOffKey
        currency = wire.currency
        expenses = try BudgetWire.decimal(wire.expenses)
        refunds = try BudgetWire.decimal(wire.refunds)
        netSpending = try BudgetWire.decimal(wire.netSpending)
        archived = wire.archived
    }
}

extension BudgetOverview {
    init(wire: Components.Schemas.BudgetAnalyticsOverview) throws {
        period = wire.period
        currencies = try wire.currencies.map(BudgetCurrencyTotal.init(wire:))
        categories = try wire.categories.map(BudgetOverviewCategory.init(wire:))
    }
}

extension BudgetCategoryDefinition {
    init(wire: Components.Schemas.BudgetAnalyticsCategory) {
        id = wire.id
        name = wire.name
        displayName = wire.displayName
        parentID = wire.parentId
        colorHue = wire.colorHue
        archived = wire.archived
        translations = wire.translations ?? [:]
    }
}

extension BudgetChartPoint {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetDailyPoint) throws {
        date = wire.date
        cumulativeSpent = try BudgetWire.decimal(wire.cumulativeSpent)
    }
}

extension BudgetChartMonth {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetSeriesMonth) throws {
        period = wire.period
        startBudget = try BudgetWire.decimal(wire.startBudget)
        spent = try BudgetWire.decimal(wire.spent)
    }
}

extension BudgetChartSeries {
    init(wire: Components.Schemas.BudgetAnalyticsMonthlyBudgetSeries) throws {
        daily = try wire.daily.map(BudgetChartPoint.init(wire:))
        months = try wire.months.map(BudgetChartMonth.init(wire:))
    }
}

struct BudgetAnalyticsCategoryWire: Codable, Hashable, Sendable {
    let archived: Bool
    let colorHue: Int?
    let createdAt: Double
    let displayName: String?
    let id: String
    let name: String
    let parentId: String?
    let translations: [String: String]?
    let updatedAt: Double
    let version: Int

    private enum CodingKeys: String, CodingKey {
        case archived, colorHue = "color_hue", createdAt = "created_at", displayName = "display_name"
        case id, name, parentId = "parent_id", translations, updatedAt = "updated_at", version
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archived = try values.decode(Bool.self, forKey: .archived)
        colorHue = try values.decodeIfPresent(Int.self, forKey: .colorHue)
        createdAt = try values.decode(Double.self, forKey: .createdAt)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        guard values.contains(.parentId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.parentId,
                .init(codingPath: values.codingPath, debugDescription: "Required parent_id is missing")
            )
        }
        parentId = try values.decodeIfPresent(String.self, forKey: .parentId)
        translations = try values.decodeIfPresent([String: String].self, forKey: .translations)
        updatedAt = try values.decode(Double.self, forKey: .updatedAt)
        version = try values.decode(Int.self, forKey: .version)
    }
}

struct BudgetAnalyticsCategoryTotalWire: Codable, Hashable, Sendable {
    let archived: Bool
    let categoryId: String?
    let currency: String
    let displayLabel: String?
    let displayName: String?
    let expenses: String
    let name: String?
    let netSpending: String
    let oneOff: Bool
    let oneOffKey: String?
    let refunds: String

    private enum CodingKeys: String, CodingKey {
        case archived, categoryId = "category_id", currency, displayLabel = "display_label"
        case displayName = "display_name", expenses, name, netSpending = "net_spending"
        case oneOff = "one_off", oneOffKey = "one_off_key", refunds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archived = try values.decode(Bool.self, forKey: .archived)
        guard values.contains(.categoryId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.categoryId,
                .init(codingPath: values.codingPath, debugDescription: "Required category_id is missing")
            )
        }
        categoryId = try values.decodeIfPresent(String.self, forKey: .categoryId)
        currency = try values.decode(String.self, forKey: .currency)
        displayLabel = try values.decodeIfPresent(String.self, forKey: .displayLabel)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        expenses = try values.decode(String.self, forKey: .expenses)
        guard values.contains(.name) else {
            throw DecodingError.keyNotFound(
                CodingKeys.name,
                .init(codingPath: values.codingPath, debugDescription: "Required name is missing")
            )
        }
        name = try values.decodeIfPresent(String.self, forKey: .name)
        netSpending = try values.decode(String.self, forKey: .netSpending)
        oneOff = try values.decodeBudgetOneOff(forKey: .oneOff)
        oneOffKey = try values.decodeIfPresent(String.self, forKey: .oneOffKey)
        refunds = try values.decode(String.self, forKey: .refunds)
    }
}

struct BudgetAnalyticsMonthlyBudgetChartsWire: Codable, Hashable, Sendable {
    let budget: Components.Schemas.BudgetAnalyticsMonthlyBudget
    let series: Components.Schemas.BudgetAnalyticsMonthlyBudgetSeries?

    private enum CodingKeys: String, CodingKey {
        case budget, series
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        budget = try values.decode(Components.Schemas.BudgetAnalyticsMonthlyBudget.self, forKey: .budget)
        guard values.contains(.series) else {
            throw DecodingError.keyNotFound(
                CodingKeys.series,
                .init(codingPath: values.codingPath, debugDescription: "Required series is missing")
            )
        }
        series = try values.decodeIfPresent(Components.Schemas.BudgetAnalyticsMonthlyBudgetSeries.self, forKey: .series)
    }
}

struct BudgetAnalyticsMonthlyBudgetSeriesCategoryWire: Codable, Hashable, Sendable {
    let categoryId: String?
    let displayLabel: String?
    let displayName: String?
    let name: String?
    let netSpending: String
    let oneOff: Bool
    let oneOffKey: String?

    private enum CodingKeys: String, CodingKey {
        case categoryId = "category_id", displayLabel = "display_label", displayName = "display_name"
        case name, netSpending = "net_spending", oneOff = "one_off", oneOffKey = "one_off_key"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.categoryId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.categoryId,
                .init(codingPath: values.codingPath, debugDescription: "Required category_id is missing")
            )
        }
        categoryId = try values.decodeIfPresent(String.self, forKey: .categoryId)
        displayLabel = try values.decodeIfPresent(String.self, forKey: .displayLabel)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        netSpending = try values.decode(String.self, forKey: .netSpending)
        oneOff = try values.decodeBudgetOneOff(forKey: .oneOff)
        oneOffKey = try values.decodeIfPresent(String.self, forKey: .oneOffKey)
    }
}

struct BudgetAnalyticsMonthlyBudgetCategorySpendWire: Codable, Hashable, Sendable {
    let archived: Bool
    let categoryId: String?
    let colorHue: Int?
    let displayLabel: String?
    let displayName: String?
    let expenses: String
    let limit: Components.Schemas.BudgetAnalyticsMonthlyBudgetCategoryLimit?
    let name: String?
    let netSpending: String
    let oneOff: Bool
    let oneOffKey: String?
    let refunds: String

    private enum CodingKeys: String, CodingKey {
        case archived, categoryId = "category_id", colorHue = "color_hue", displayLabel = "display_label"
        case displayName = "display_name", expenses, limit, name, netSpending = "net_spending"
        case oneOff = "one_off", oneOffKey = "one_off_key", refunds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        archived = try values.decode(Bool.self, forKey: .archived)
        categoryId = try values.decodeIfPresent(String.self, forKey: .categoryId)
        colorHue = try values.decodeIfPresent(Int.self, forKey: .colorHue)
        displayLabel = try values.decodeIfPresent(String.self, forKey: .displayLabel)
        displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        expenses = try values.decode(String.self, forKey: .expenses)
        limit = try values.decodeIfPresent(Components.Schemas.BudgetAnalyticsMonthlyBudgetCategoryLimit.self, forKey: .limit)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        netSpending = try values.decode(String.self, forKey: .netSpending)
        oneOff = try values.decodeBudgetOneOff(forKey: .oneOff)
        oneOffKey = try values.decodeIfPresent(String.self, forKey: .oneOffKey)
        refunds = try values.decode(String.self, forKey: .refunds)
    }
}

private extension KeyedDecodingContainer {
    func decodeBudgetOneOff(forKey key: Key) throws -> Bool {
        guard contains(key) else { return false }
        if try decodeNil(forKey: key) {
            throw DecodingError.valueNotFound(
                Bool.self,
                .init(codingPath: codingPath + [key], debugDescription: "one_off must be a Boolean when present")
            )
        }
        return try decodeIfPresent(Bool.self, forKey: key) ?? false
    }
}
