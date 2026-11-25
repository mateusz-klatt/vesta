import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
import SwiftUI
import UIKit
@testable import Vesta

private enum BudgetFixtures {
    static func monthly(
        period: String = "2026-11",
        currentMonth: String? = "2026-11",
        currency: String = "PLN",
        availableCurrencies: [String] = ["PLN", "EUR"],
        ledgerAsOf: Date? = Date(timeIntervalSince1970: 1_795_557_000),
        spent: Decimal = 500,
        categories: [BudgetCategory] = []
    ) -> BudgetMonthly {
        BudgetMonthly(
            period: period,
            currentMonth: currentMonth,
            currency: currency,
            availableCurrencies: availableCurrencies,
            ledgerAsOf: ledgerAsOf,
            summary: BudgetSummary(startBudget: 2_000, spent: spent, remaining: 2_000 - spent),
            pace: nil,
            categories: categories
        )
    }

    static func page(_ transactions: [BudgetTransaction] = [], nextCursor: String? = nil, total: Int? = nil) -> BudgetTransactionPage {
        BudgetTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor,
            filteredTotal: total ?? transactions.count
        )
    }

    static func transaction(_ id: String, amount: Decimal = 1) -> BudgetTransaction {
        BudgetTransaction(
            id: "acc\u{1f}\(id)", accountID: "acc", entryReference: id,
            amount: amount, isCredit: false, currency: "PLN", bookingDate: nil,
            payee: nil, details: nil, categoryID: nil, kind: "purchase"
        )
    }

    static let status = BudgetStatus(dataAsOf: Date(timeIntervalSince1970: 300))
}

final class BudgetMappingTests: XCTestCase {
    func testMonthlyMappingPreservesDecimalPrecisionAndNullables() throws {
        let wire = try JSONDecoder().decode(
            Components.Schemas.BudgetAnalyticsMonthlyBudget.self,
            from: Data(Self.monthlyJSON.utf8)
        )
        let monthly = try BudgetMonthly(wire: wire)

        XCTAssertEqual(monthly.period, "2026-11")
        XCTAssertEqual(monthly.currentMonth, "2026-11")
        XCTAssertEqual(monthly.currency, "PLN")
        XCTAssertEqual(monthly.availableCurrencies, ["PLN", "EUR"])
        XCTAssertNil(monthly.ledgerAsOf)
        XCTAssertEqual(monthly.summary?.startBudget, Decimal(string: "10000.123456789012345678"))
        XCTAssertEqual(monthly.summary?.spent, Decimal(string: "2345.67"))
        XCTAssertEqual(monthly.pace?.status, .runsOut)
        XCTAssertEqual(monthly.pace?.projectedMonthSpend, Decimal(string: "2250.0625"))
        XCTAssertEqual(monthly.pace?.exhaustionDay, 26)
        XCTAssertEqual(monthly.categories.count, 2)
        XCTAssertEqual(monthly.categories[0].name, "Weekly food")
        XCTAssertFalse(monthly.categories[0].isOneOff)
        XCTAssertNil(monthly.categories[0].oneOffKey)
        XCTAssertEqual(monthly.categories[0].limit?.monthlyLimit, Decimal(string: "960.08"))
        XCTAssertEqual(monthly.categories[0].limit?.percentUsedFloor, Decimal(string: "125.9"))
        XCTAssertTrue(monthly.categories[0].limit?.isOver == true)
        XCTAssertNil(monthly.categories[1].categoryID)
        XCTAssertNil(monthly.categories[1].name)
        XCTAssertNil(monthly.categories[1].limit)
        XCTAssertEqual(monthly.categories[1].id, "uncategorised")
    }

    func testMonthlyMappingReadsCoverageLedgerAsOf() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.monthlyJSON.utf8)) as? [String: Any])
        var coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        coverage["ledger_as_of"] = 1_795_557_123.5
        object["coverage"] = coverage
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire = try JSONDecoder().decode(Components.Schemas.BudgetAnalyticsMonthlyBudget.self, from: data)
        let monthly = try BudgetMonthly(wire: wire)

        XCTAssertEqual(monthly.ledgerAsOf, Date(timeIntervalSince1970: 1_795_557_123.5))
    }

    func testOneOffCategoryKeepsOneOffKeyIdentityAndHasNoDrillDown() throws {
        let keyA = String(repeating: "a", count: 64)
        let keyB = String(repeating: "b", count: 64)
        let keyC = String(repeating: "c", count: 64)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.monthlyJSON.utf8)) as? [String: Any])
        object["category_spend"] = [
            [
                "category_id": "groceries", "name": "Groceries", "display_label": NSNull(), "display_name": NSNull(),
                "archived": false, "color_hue": NSNull(), "one_off": false, "one_off_key": NSNull(),
                "expenses": "100.00", "refunds": "0", "net_spending": "100.00", "limit": NSNull(),
            ],
            [
                "category_id": "groceries", "name": "Bulk pantry", "display_label": NSNull(), "display_name": NSNull(),
                "archived": false, "color_hue": NSNull(), "one_off": true, "one_off_key": keyA,
                "expenses": "50.00", "refunds": "0", "net_spending": "50.00", "limit": NSNull(),
            ],
            [
                "category_id": "groceries", "name": "Party supplies", "display_label": NSNull(), "display_name": NSNull(),
                "archived": false, "color_hue": NSNull(), "one_off": true, "one_off_key": keyB,
                "expenses": "25.00", "refunds": "0", "net_spending": "25.00", "limit": NSNull(),
            ],
            [
                "category_id": NSNull(), "name": "One-off gift", "display_label": NSNull(), "display_name": NSNull(),
                "archived": false, "color_hue": NSNull(), "one_off": true, "one_off_key": keyC,
                "expenses": "10.00", "refunds": "0", "net_spending": "10.00", "limit": NSNull(),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire = try JSONDecoder().decode(Components.Schemas.BudgetAnalyticsMonthlyBudget.self, from: data)
        let monthly = try BudgetMonthly(wire: wire)

        XCTAssertEqual(monthly.categories.count, 4)
        XCTAssertEqual(Set(monthly.categories.map(\.id)).count, 4)
        XCTAssertEqual(monthly.categories[0].id, "groceries")
        XCTAssertFalse(monthly.categories[0].isOneOff)
        XCTAssertEqual(monthly.categories[1].id, keyA)
        XCTAssertEqual(monthly.categories[1].oneOffKey, keyA)
        XCTAssertEqual(monthly.categories[1].categoryID, "groceries")
        XCTAssertTrue(monthly.categories[1].isOneOff)
        XCTAssertEqual(monthly.categories[2].id, keyB)
        XCTAssertEqual(monthly.categories[2].oneOffKey, keyB)
        XCTAssertTrue(monthly.categories[2].isOneOff)
        XCTAssertEqual(monthly.categories[3].id, keyC)
        XCTAssertNil(monthly.categories[3].categoryID)
        XCTAssertTrue(monthly.categories[3].isOneOff)
    }

    func testMonthlyMappingHandlesMissingSummaryAndPace() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.monthlyJSON.utf8)) as? [String: Any])
        object["summary"] = NSNull()
        object["pace"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: object)
        let wire = try JSONDecoder().decode(Components.Schemas.BudgetAnalyticsMonthlyBudget.self, from: data)
        let monthly = try BudgetMonthly(wire: wire)
        XCTAssertNil(monthly.summary)
        XCTAssertNil(monthly.pace)
    }

    func testTransactionMappingPreservesAmountAndNullableDates() throws {
        let wire = try JSONDecoder().decode(
            Components.Schemas.BudgetAnalyticsTransactions.self,
            from: Data(Self.transactionsJSON.utf8)
        )
        let page = try BudgetTransactionPage(wire: wire)
        let transaction = try XCTUnwrap(page.transactions.first)

        XCTAssertEqual(page.nextCursor, "next-page")
        XCTAssertEqual(page.filteredTotal, 7)
        XCTAssertEqual(transaction.amount, Decimal(string: "12.340000000000000001"))
        XCTAssertEqual(transaction.signedAmount, Decimal(string: "-12.340000000000000001"))
        XCTAssertEqual(transaction.bookingDate, "2026-11-20")
        XCTAssertEqual(transaction.payee, "Shop")
        XCTAssertEqual(transaction.details, "Groceries · Card purchase")
        XCTAssertEqual(transaction.categoryID, "groceries")
        XCTAssertEqual(transaction.id, "acc\u{1f}tx-1")
    }

    func testStatusMappingUsesLatestSuccessfulComponentUpdate() throws {
        let wire = try JSONDecoder().decode(Components.Schemas.BudgetStatus.self, from: Data(Self.statusJSON.utf8))
        XCTAssertEqual(BudgetStatus(wire: wire).dataAsOf, Date(timeIntervalSince1970: 300))
        let empty = try JSONDecoder().decode(Components.Schemas.BudgetStatus.self, from: Data(#"{"status":[]}"#.utf8))
        XCTAssertNil(BudgetStatus(wire: empty).dataAsOf)
    }

    static let monthlyJSON = #"""
    {
      "period":"2026-11","start":"2026-11-01","end":"2026-12-01",
      "cutoff":"2026-11-24","current_month":"2026-11","evaluated_at":1795557600,
      "evaluation_date":"2026-11-24","evaluation_timezone":"Europe/Warsaw",
      "currency":"PLN","available_currencies":["PLN","EUR"],
      "configuration":{"status":"ready","source":"saved","income_window":null},
      "coverage":{
        "ledger_as_of":null,"stale_selected_accounts":0,"purchase_date_fallback_count":0,
        "pending_transfer_rows":0,"transfer_scan_limited":false,"provisional":false,"has_activity":true
      },
      "summary":{"start_budget":"10000.123456789012345678","spent":"2345.67","remaining":"7654.45"},
      "expected_income":null,
      "pace":{
        "basis":"received","budget":"10000.123456789012345678","status":"runs_out",
        "daily_rate":null,"projected_month_spend":{"numerator":"4500.125","denominator":2},"exhaustion_day":26
      },
      "category_spend":[
        {
          "category_id":"groceries","name":"Groceries","display_label":null,"display_name":"Weekly food",
          "archived":false,"color_hue":null,"one_off":false,"one_off_key":null,
          "expenses":"1200.10","refunds":"0.00","net_spending":"1200.10",
          "limit":{
            "monthly_limit":"960.08","remaining":"-240.02","over_by":"240.02",
            "percent_used_floor":"125.9","warning_percent":80,"status":"exceeded"
          }
        },
        {
          "category_id":null,"name":null,"display_label":null,"display_name":null,
          "archived":false,"color_hue":null,"one_off":false,"one_off_key":null,
          "expenses":"1.01","refunds":"0","net_spending":"1.01","limit":null
        }
      ],
      "pass_through":null,
      "card_exposure":{"status":"unavailable","amount":null,"as_of_date":null}
    }
    """#

    static let transactionsJSON = #"""
    {
      "period":"2026-11","start":"2026-11-01","end":"2026-12-01","snapshot_digest":"digest",
      "filtered_total":7,"next_cursor":"next-page",
      "transactions":[{
        "account_id":"acc","entry_reference":"tx-1","amount":"12.340000000000000001",
        "currency":"PLN","credit_debit_indicator":"DBIT","status":"BOOK",
        "booking_date":null,"value_date":"2026-11-20","transaction_date":null,
        "remittance_information":["Groceries","Card purchase"],"source":"api",
        "observed_at":100,"api_observed_at":null,"fingerprint":"fingerprint","transfer_fingerprint":"transfer",
        "annotation":{
          "version":1,"mode":"automatic","category_id":null,"kind":"purchase","stale":false,
          "label":null,"display_label":null
        },
        "effective":{"kind":"purchase","category_id":"groceries","source":"rule","rule_id":null},
        "metadata":{"creditor_name":"Shop","debtor_name":null,"mcc":null},
        "transfer":{"status":"none","decision_id":null,"candidate_count":0,"ambiguous":false}
      }]
    }
    """#

    static let statusJSON = #"""
    {
      "status":[{
        "connection":"bank","owner":"owner","enabled":true,"paused":false,
        "control_version":1,"selection_policy_version":1,"configured_accounts":1,"selected_accounts":1,
        "transactions":2,"unresolved":0,"uncertain_transactions":0,
        "offline_imports":0,"offline_transactions":0,"offline_unresolved":0,
        "last_attempt":null,"last_success":100,"next_attempt":200,"last_error":null,
        "failures":0,"valid_until":null,"renewal_due":false,
        "request_limits":{"next_attempt":200,"retry_at":null,"suspended":false},
        "accounts":[{
          "id":"acc","enabled":true,"configured":true,"paused":false,"control_version":1,"kind":"bank",
          "kind_confirmed_at":null,"last_attempt":null,"last_success":150,"last_error":null,
          "components":{
            "transactions":{
              "last_attempt":null,"last_success":300,"last_error":null,"failures":0,
              "next_attempt":400,"state":"ok","retry_at":null,"suspended":false,
              "stale":false,"age_seconds":null,"stale_after_seconds":600
            },
            "balances":{
              "last_attempt":null,"last_success":250,"last_error":null,"failures":0,
              "next_attempt":400,"state":"ok","retry_at":null,"suspended":false,
              "stale":false,"age_seconds":null,"stale_after_seconds":600
            }
          }
        }]
      }]
    }
    """#
}

private actor MockBudgetAPI: BudgetAPI {
    enum Call: Equatable {
        case monthly(String, String?)
        case transactions(String, String?, String?, String?, Int)
        case status
    }

    typealias MonthlyHandler = @Sendable (String, String?) async throws -> BudgetMonthly
    typealias TransactionsHandler = @Sendable (String, String?, String?, String?, Int) async throws -> BudgetTransactionPage
    typealias StatusHandler = @Sendable () async throws -> BudgetStatus

    private let monthlyHandler: MonthlyHandler
    private let transactionsHandler: TransactionsHandler
    private let statusHandler: StatusHandler
    private(set) var calls: [Call] = []

    init(
        monthly: @escaping MonthlyHandler = { period, currency in BudgetFixtures.monthly(period: period, currency: currency ?? "PLN") },
        transactions: @escaping TransactionsHandler = { _, _, _, _, _ in BudgetFixtures.page() },
        status: @escaping StatusHandler = { BudgetFixtures.status }
    ) {
        monthlyHandler = monthly
        transactionsHandler = transactions
        statusHandler = status
    }

    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly {
        calls.append(.monthly(period, currency))
        return try await monthlyHandler(period, currency)
    }

    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage {
        calls.append(.transactions(period, currency, categoryID, cursor, limit))
        return try await transactionsHandler(period, currency, categoryID, cursor, limit)
    }

    func status() async throws -> BudgetStatus {
        calls.append(.status)
        return try await statusHandler()
    }
}

private actor BudgetResponseGate {
    private var waiting = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiting }

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else {
                waiting = true
                self.continuation = continuation
            }
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class BudgetStoreTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: 1_795_557_600) }

    private func store(_ api: any BudgetAPI, now: Date? = nil) -> BudgetStore {
        BudgetStore(api: api, now: now ?? self.now)
    }

    func testLoadedPublishesOverviewTransactionsAndFreshness() async throws {
        let transaction = BudgetFixtures.transaction("one")
        let mock = MockBudgetAPI(transactions: { _, _, _, _, _ in BudgetFixtures.page([transaction]) })
        let store = store(mock)
        XCTAssertEqual(store.period, "2026-11")

        await store.load()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.overview, BudgetFixtures.monthly())
        XCTAssertEqual(store.transactions, [transaction])
        XCTAssertEqual(store.currency, "PLN")
        XCTAssertEqual(store.availableCurrencies, ["PLN", "EUR"])
        XCTAssertEqual(store.dataAsOf, BudgetFixtures.monthly().ledgerAsOf)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.monthly("2026-11", nil)))
        XCTAssertTrue(calls.contains(.transactions("2026-11", "PLN", nil, nil, 50)))
        XCTAssertFalse(calls.contains(.status))
    }

    func testDataAsOfUsesCoverageLedgerAsOfInsteadOfStatusSync() async {
        let expectedAsOf = Date(timeIntervalSince1970: 1_795_500_123)
        let mock = MockBudgetAPI(
            monthly: { period, currency in
                BudgetFixtures.monthly(period: period, currency: currency ?? "PLN", ledgerAsOf: expectedAsOf)
            },
            status: {
                XCTFail("BudgetStore must read dataAsOf from monthly coverage.ledger_as_of, not /status")
                return BudgetStatus(dataAsOf: Date(timeIntervalSince1970: 1))
            }
        )
        let store = store(mock)
        await store.load()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.dataAsOf, expectedAsOf)

        let nilAsOfMock = MockBudgetAPI(
            monthly: { period, currency in
                BudgetFixtures.monthly(period: period, currency: currency ?? "PLN", ledgerAsOf: nil)
            },
            status: { BudgetStatus(dataAsOf: Date(timeIntervalSince1970: 999)) }
        )
        let nilStore = self.store(nilAsOfMock)
        await nilStore.load()
        XCTAssertNil(nilStore.dataAsOf)
    }

    func testForbiddenAndUnavailableStates() async {
        let forbidden = store(MockBudgetAPI(monthly: { _, _ in throw BudgetError.forbidden }))
        await forbidden.load()
        XCTAssertEqual(forbidden.state, .forbidden)
        XCTAssertEqual(forbidden.failure, .forbidden)

        let unavailable = store(MockBudgetAPI(transactions: { _, _, _, _, _ in throw BudgetError.unavailable }))
        await unavailable.load()
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.failure, .unavailable)
    }

    func testStaleResponseIsIgnored() async throws {
        let gate = BudgetResponseGate()
        let mock = MockBudgetAPI(monthly: { period, _ in
            if period == "2026-11" { await gate.wait() }
            return BudgetFixtures.monthly(period: period)
        }, transactions: { period, _, _, _, _ in
            BudgetFixtures.page([BudgetFixtures.transaction(period)])
        })
        let store = store(mock)
        let oldLoad = Task { await store.load() }
        try await waitUntil("the held monthly response") { await gate.isWaiting }

        await store.previousMonth()
        XCTAssertEqual(store.overview?.period, "2026-10")
        await gate.release()
        await oldLoad.value

        XCTAssertEqual(store.period, "2026-10")
        XCTAssertEqual(store.overview?.period, "2026-10")
        XCTAssertEqual(store.transactions.map(\.entryReference), ["2026-10"])
    }

    func testPeriodNavigationDoesNotEnterFutureMonth() async {
        let mock = MockBudgetAPI()
        let store = store(mock)
        await store.load()

        await store.previousMonth()
        XCTAssertEqual(store.period, "2026-10")
        await store.nextMonth()
        XCTAssertEqual(store.period, "2026-11")
        let before = await mock.calls.count
        await store.nextMonth()
        let after = await mock.calls.count
        XCTAssertEqual(after, before)
    }

    func testCurrencyChangeReloadsBothAnalyticsRequests() async {
        let mock = MockBudgetAPI()
        let store = store(mock)
        await store.load()

        await store.selectCurrency("EUR")

        XCTAssertEqual(store.currency, "EUR")
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.monthly("2026-11", "EUR")))
        XCTAssertTrue(calls.contains(.transactions("2026-11", "EUR", nil, nil, 50)))
    }

    func testPagingAppendsWithoutDuplicates() async {
        let one = BudgetFixtures.transaction("one")
        let two = BudgetFixtures.transaction("two")
        let three = BudgetFixtures.transaction("three")
        let mock = MockBudgetAPI(transactions: { _, _, _, cursor, _ in
            if cursor == nil { return BudgetFixtures.page([one, two], nextCursor: "page-2", total: 3) }
            return BudgetFixtures.page([two, three], total: 3)
        })
        let store = store(mock)
        await store.load()

        await store.loadMore()

        XCTAssertEqual(store.transactions, [one, two, three])
        XCTAssertNil(store.nextCursor)
        XCTAssertEqual(store.filteredTotal, 3)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.transactions("2026-11", "PLN", nil, "page-2", 50)))
    }

    func testCategoryFilterIsPassedThroughAndClears() async {
        let mock = MockBudgetAPI()
        let store = store(mock)
        await store.load()

        await store.selectCategory("groceries")
        var calls = await mock.calls
        XCTAssertTrue(calls.contains(.transactions("2026-11", "PLN", "groceries", nil, 50)))
        XCTAssertEqual(store.categoryID, "groceries")

        await store.selectCategory(nil)
        calls = await mock.calls
        XCTAssertTrue(calls.contains(.transactions("2026-11", "PLN", nil, nil, 50)))
        XCTAssertNil(store.categoryID)
    }

    func testClearDropsContentAndIgnoresInflightResponse() async throws {
        let gate = BudgetResponseGate()
        let mock = MockBudgetAPI(monthly: { period, currency in
            await gate.wait()
            return BudgetFixtures.monthly(period: period, currency: currency ?? "PLN")
        }, transactions: { _, _, _, _, _ in
            BudgetFixtures.page([BudgetFixtures.transaction("sensitive")])
        })
        let store = store(mock)
        let load = Task { await store.load() }
        try await waitUntil("the held clear response") { await gate.isWaiting }

        store.clear()
        await gate.release()
        await load.value

        XCTAssertNil(store.overview)
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertNil(store.dataAsOf)
        XCTAssertTrue(store.availableCurrencies.isEmpty)
    }

    func testFirstTransactionsAndCursorPagesSendResolvedAndIdenticalFilters() async {
        let one = BudgetFixtures.transaction("one")
        let two = BudgetFixtures.transaction("two")
        let mock = MockBudgetAPI(
            monthly: { period, currency in
                BudgetFixtures.monthly(period: period, currency: currency ?? "EUR", availableCurrencies: ["EUR", "PLN"])
            },
            transactions: { _, _, category, cursor, _ in
                if category == "groceries", cursor == nil {
                    return BudgetFixtures.page([one], nextCursor: "page-2", total: 2)
                }
                if category == "groceries", cursor == "page-2" {
                    return BudgetFixtures.page([two], nextCursor: nil, total: 2)
                }
                return BudgetFixtures.page([one], nextCursor: "root-page-2", total: 2)
            }
        )
        let store = store(mock)

        await store.load()
        await store.selectCategory("groceries")
        await store.loadMore()

        let txCalls = await mock.calls.filter {
            if case .transactions = $0 { return true }
            return false
        }
        XCTAssertEqual(txCalls, [
            .transactions("2026-11", "EUR", nil, nil, 50),
            .transactions("2026-11", "EUR", "groceries", nil, 50),
            .transactions("2026-11", "EUR", "groceries", "page-2", 50),
        ])
    }

    func testStaleCursor409RestartsPageSequenceAndKeepsLoadMoreActive() async {
        let oldOne = BudgetFixtures.transaction("old-1")
        let newOne = BudgetFixtures.transaction("new-1")
        let newTwo = BudgetFixtures.transaction("new-2")
        let newThree = BudgetFixtures.transaction("new-3")
        let initialAsOf = Date(timeIntervalSince1970: 1_795_557_000)
        let refreshedAsOf = Date(timeIntervalSince1970: 1_795_558_000)
        actor RestartState {
            var sawStale = false
            func markStale() { sawStale = true }
        }
        let state = RestartState()
        let restartMock = MockBudgetAPI(
            monthly: { period, currency in
                if await state.sawStale {
                    return BudgetFixtures.monthly(
                        period: period, currency: currency ?? "PLN",
                        ledgerAsOf: refreshedAsOf, spent: 750
                    )
                }
                return BudgetFixtures.monthly(
                    period: period, currency: currency ?? "PLN",
                    ledgerAsOf: initialAsOf, spent: 500
                )
            },
            transactions: { _, _, _, cursor, _ in
                switch cursor {
                case nil:
                    if await state.sawStale {
                        return BudgetFixtures.page([newOne, newTwo], nextCursor: "fresh-cursor-2", total: 3)
                    }
                    return BudgetFixtures.page([oldOne], nextCursor: "stale-cursor-1", total: 3)
                case "stale-cursor-1":
                    await state.markStale()
                    throw BudgetError.staleCursor
                case "fresh-cursor-2":
                    return BudgetFixtures.page([newThree], nextCursor: nil, total: 3)
                default:
                    XCTFail("Unexpected cursor \(String(describing: cursor))")
                    return BudgetFixtures.page()
                }
            }
        )
        let restartStore = store(restartMock)
        await restartStore.load()
        XCTAssertEqual(restartStore.overview?.summary?.spent, 500)
        XCTAssertEqual(restartStore.dataAsOf, initialAsOf)
        XCTAssertEqual(restartStore.nextCursor, "stale-cursor-1")

        await restartStore.loadMore()

        XCTAssertEqual(restartStore.state, .loaded)
        XCTAssertFalse(restartStore.isLoadingMore)
        XCTAssertEqual(restartStore.overview?.summary?.spent, 750)
        XCTAssertEqual(restartStore.dataAsOf, refreshedAsOf)
        XCTAssertEqual(restartStore.transactions, [newOne, newTwo])
        XCTAssertEqual(restartStore.nextCursor, "fresh-cursor-2")
        XCTAssertEqual(restartStore.filteredTotal, 3)

        let monthlyCountAfterRecovery = await restartMock.calls.filter {
            if case .monthly = $0 { return true }
            return false
        }.count
        XCTAssertEqual(monthlyCountAfterRecovery, 2)

        await restartStore.loadMore()

        XCTAssertEqual(restartStore.state, .loaded)
        XCTAssertFalse(restartStore.isLoadingMore)
        XCTAssertEqual(restartStore.transactions, [newOne, newTwo, newThree])
        XCTAssertNil(restartStore.nextCursor)
    }

    func testOverlappingReloadDuringPaginationDropsOldCursorAndIsNeverCancelled() async throws {
        // 1. Currency change racing with queued loadMore()
        actor CancellationTracker {
            var reloadCancelled = false
            func markCancelled() { reloadCancelled = true }
        }
        let currencyTracker = CancellationTracker()
        let currencyGate = BudgetResponseGate()
        let currencyMock = MockBudgetAPI(
            monthly: { period, currency in
                if currency == "EUR" {
                    await currencyGate.wait()
                    if Task.isCancelled { await currencyTracker.markCancelled() }
                }
                return BudgetFixtures.monthly(period: period, currency: currency ?? "PLN")
            },
            transactions: { _, currency, _, cursor, _ in
                if cursor == "old-cursor" {
                    XCTFail("Old cursor must never be sent after a reload reservation")
                }
                if currency == "EUR" {
                    return BudgetFixtures.page([BudgetFixtures.transaction("eur-tx")])
                }
                return BudgetFixtures.page([BudgetFixtures.transaction("pln-tx")], nextCursor: "old-cursor", total: 2)
            }
        )
        let currencyStore = store(currencyMock)
        await currencyStore.load()
        XCTAssertEqual(currencyStore.nextCursor, "old-cursor")

        let currencyReload = Task { await currencyStore.selectCurrency("EUR") }
        let queuedCurrencyLoadMore = Task { await currencyStore.loadMore() }
        try await waitUntil("held EUR monthly reload") { await currencyGate.isWaiting }
        // Even while suspended, a direct loadMore() must also see the reserved reload.
        await currencyStore.loadMore()
        await currencyGate.release()
        await currencyReload.value
        await queuedCurrencyLoadMore.value

        let currencyWasCancelled = await currencyTracker.reloadCancelled
        XCTAssertFalse(currencyWasCancelled)
        XCTAssertEqual(currencyStore.state, .loaded)
        XCTAssertEqual(currencyStore.currency, "EUR")
        XCTAssertEqual(currencyStore.transactions.map(\.entryReference), ["eur-tx"])
        let currencyCalls = await currencyMock.calls
        XCTAssertFalse(currencyCalls.contains(.transactions("2026-11", "PLN", nil, "old-cursor", 50)))

        // 2. Month change racing with queued loadMore()
        let monthTracker = CancellationTracker()
        let monthGate = BudgetResponseGate()
        let monthMock = MockBudgetAPI(
            monthly: { period, currency in
                if period == "2026-10" {
                    await monthGate.wait()
                    if Task.isCancelled { await monthTracker.markCancelled() }
                }
                return BudgetFixtures.monthly(period: period, currency: currency ?? "PLN")
            },
            transactions: { period, _, _, cursor, _ in
                if cursor == "nov-cursor" {
                    XCTFail("Old cursor must never be sent after month navigation")
                }
                if period == "2026-10" {
                    return BudgetFixtures.page([BudgetFixtures.transaction("oct-tx")])
                }
                return BudgetFixtures.page([BudgetFixtures.transaction("nov-tx")], nextCursor: "nov-cursor", total: 2)
            }
        )
        let monthStore = store(monthMock)
        await monthStore.load()
        XCTAssertEqual(monthStore.nextCursor, "nov-cursor")

        let monthReload = Task { await monthStore.previousMonth() }
        let queuedMonthLoadMore = Task { await monthStore.loadMore() }
        try await waitUntil("held 2026-10 monthly reload") { await monthGate.isWaiting }
        await monthStore.loadMore()
        await monthGate.release()
        await monthReload.value
        await queuedMonthLoadMore.value

        let monthWasCancelled = await monthTracker.reloadCancelled
        XCTAssertFalse(monthWasCancelled)
        XCTAssertEqual(monthStore.state, .loaded)
        XCTAssertEqual(monthStore.period, "2026-10")
        XCTAssertEqual(monthStore.transactions.map(\.entryReference), ["oct-tx"])
    }

    func testDenial401And403ClearAllStoreDataAndCancelPendingWork() async throws {
        for denialError in [BudgetError.unauthorized, BudgetError.forbidden] {
            let expectedState: BudgetStore.State = denialError == .forbidden ? .forbidden : .unauthorized
            let mock = MockBudgetAPI(transactions: { _, _, _, cursor, _ in
                if cursor == nil {
                    return BudgetFixtures.page([BudgetFixtures.transaction("one")], nextCursor: "page-2", total: 2)
                }
                throw denialError
            })
            let store = store(mock)
            await store.load()
            await store.selectCategory("groceries")
            XCTAssertNotNil(store.overview)
            XCTAssertFalse(store.transactions.isEmpty)
            XCTAssertEqual(store.nextCursor, "page-2")
            XCTAssertEqual(store.categoryID, "groceries")

            // Denial on pagination must wipe all stored data and move into denial state.
            await store.loadMore()

            XCTAssertEqual(store.state, expectedState)
            XCTAssertTrue(store.isDenied)
            XCTAssertEqual(store.failure, denialError)
            XCTAssertNil(store.overview)
            XCTAssertTrue(store.transactions.isEmpty)
            XCTAssertEqual(store.filteredTotal, 0)
            XCTAssertNil(store.nextCursor)
            XCTAssertNil(store.dataAsOf)
            XCTAssertTrue(store.availableCurrencies.isEmpty)
            XCTAssertNil(store.currency)
            XCTAssertNil(store.categoryID)
            XCTAssertFalse(store.isLoadingMore)

            // Denial during refresh after overview was already populated must wipe all cached data too.
            actor RefreshStage {
                var failTransactions = false
                func arm() { failTransactions = true }
            }
            let stage = RefreshStage()
            let refreshMock = MockBudgetAPI(
                monthly: { period, _ in BudgetFixtures.monthly(period: period) },
                transactions: { _, _, _, _, _ in
                    if await stage.failTransactions { throw denialError }
                    return BudgetFixtures.page([BudgetFixtures.transaction("tx")], nextCursor: "c1", total: 2)
                }
            )
            let refreshStore = self.store(refreshMock)
            await refreshStore.load()
            XCTAssertNotNil(refreshStore.overview)
            XCTAssertEqual(refreshStore.transactions.count, 1)
            XCTAssertEqual(refreshStore.nextCursor, "c1")

            await stage.arm()
            await refreshStore.refresh()

            XCTAssertEqual(refreshStore.state, expectedState)
            XCTAssertTrue(refreshStore.isDenied)
            XCTAssertNil(refreshStore.overview)
            XCTAssertTrue(refreshStore.transactions.isEmpty)
            XCTAssertNil(refreshStore.nextCursor)
            XCTAssertNil(refreshStore.dataAsOf)
            XCTAssertTrue(refreshStore.availableCurrencies.isEmpty)
            XCTAssertNil(refreshStore.currency)
            XCTAssertNil(refreshStore.categoryID)
        }
    }

    func testDenialCancelsInFlightWork() async throws {
        for denialError in [BudgetError.unauthorized, BudgetError.forbidden] {
            actor CancelTracker {
                var wasCancelled = false
                func mark() { wasCancelled = true }
            }
            let tracker = CancelTracker()
            let gate = BudgetResponseGate()
            let mock = MockBudgetAPI(monthly: { period, _ in
                if period == "2026-11" {
                    await gate.wait()
                    if Task.isCancelled { await tracker.mark() }
                }
                if period == "2026-10" {
                    throw denialError
                }
                return BudgetFixtures.monthly(period: period)
            })
            let store = store(mock)
            let pending = Task { await store.load() }
            try await waitUntil("held load") { await gate.isWaiting }

            await store.previousMonth()
            await gate.release()
            await pending.value

            let cancelled = await tracker.wasCancelled
            XCTAssertTrue(cancelled)
            XCTAssertEqual(store.state, denialError == .forbidden ? .forbidden : .unauthorized)
            XCTAssertNil(store.overview)
            XCTAssertTrue(store.transactions.isEmpty)
            XCTAssertNil(store.nextCursor)
        }
    }

    func testClearIsTerminalSoQueuedViewActionsCannotRestartStore() async {
        let mock = MockBudgetAPI(transactions: { _, _, _, _, _ in
            BudgetFixtures.page([BudgetFixtures.transaction("one")], nextCursor: "page-2", total: 2)
        })
        let store = store(mock)
        await store.load()
        let countAtClear = await mock.calls.count

        store.clear()

        await store.load()
        await store.refresh()
        await store.previousMonth()
        await store.nextMonth()
        await store.selectCurrency("EUR")
        await store.selectCategory("groceries")
        await store.loadMore()

        let countAfter = await mock.calls.count
        XCTAssertEqual(countAfter, countAtClear)
        XCTAssertTrue(store.isCleared)
        XCTAssertNil(store.overview)
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertNil(store.nextCursor)
    }

    func testDenialIsTerminalSoQueuedLoadSendsNothingAndClosesSheet() async throws {
        for denialError in [BudgetError.unauthorized, BudgetError.forbidden] {
            let mock = MockBudgetAPI(monthly: { _, _ in throw denialError })
            let store = store(mock)

            await store.load()

            XCTAssertTrue(store.isDenied)
            let callsAfterDenial = await mock.calls.count

            // Every action (including a queued load()) must be a no-op after 401 or 403.
            await store.load()
            await store.refresh()
            await store.previousMonth()
            await store.nextMonth()
            await store.selectCurrency("EUR")
            await store.selectCategory("groceries")
            await store.loadMore()

            let callsAfterQueued = await mock.calls.count
            XCTAssertEqual(callsAfterQueued, callsAfterDenial)
            XCTAssertTrue(store.isDenied)

            // Route denial through BudgetView's close callback (onClose -> HomeView.closeBudget()).
            var closeCallbackCount = 0
            let view = BudgetView(store: store) { closeCallbackCount += 1 }
            XCTAssertTrue(view.closeIfDenied())
            XCTAssertEqual(closeCallbackCount, 1)

            // Also verify BudgetView hosted in a UIWindow triggers onClose automatically on denial.
            var hostedClosed = false
            let hostedStore = self.store(MockBudgetAPI(monthly: { _, _ in throw denialError }))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let controller = UIHostingController(rootView: BudgetView(store: hostedStore) {
                hostedClosed = true
            })
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            // Hosting a SwiftUI view in a window waits on the run loop. Under coverage
            // instrumentation on CI that has taken ~20s, so allow more than the 5s default.
            try await waitUntil("BudgetView denial closes the sheet", timeout: .seconds(60)) { hostedClosed }
            XCTAssertTrue(hostedStore.isDenied)
            XCTAssertTrue(hostedClosed)
        }
    }

    func testSignOutUsesSamePathToClearBudgetStore() async throws {
        let mock = MockHestiaAPI()
        let app = AppState(
            api: mock,
            receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            events: { AsyncStream { $0.finish() } }
        )
        app.nativeBudgetEnabled = true
        await mock.setFeatures([.capabilities, .budgetNativeRead])
        await mock.setWhoami(role: "admin")
        await app.connect()

        let store = try XCTUnwrap(app.makeBudgetStore(now: now))
        await store.load()
        XCTAssertEqual(store.state, .loaded)
        XCTAssertNotNil(store.overview)

        await app.signOut()

        XCTAssertTrue(store.isCleared)
        XCTAssertNil(store.overview)
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertNil(store.nextCursor)
        await store.load()
        XCTAssertNil(store.overview)
    }

    func testPeriodAndNavigationWithTimezoneEastOfWarsaw() async throws {
        let previousTZ = TimeZone.ReferenceType.default
        TimeZone.ReferenceType.default = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        defer { TimeZone.ReferenceType.default = previousTZ }

        // 2026-11-30 22:30 UTC is 2026-11-30 23:30 in Europe/Warsaw, but 2026-12-01 07:30 in Asia/Tokyo.
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-30T22:30:00Z"))
        XCTAssertEqual(Calendar.current.component(.month, from: instant), 12)

        let mock = MockBudgetAPI()
        let store = BudgetStore(api: mock, now: instant)
        XCTAssertEqual(store.period, "2026-11")
        XCTAssertFalse(store.canGoNext)

        await store.load()
        await store.nextMonth()
        let callsAfterBlockedNext = await mock.calls
        XCTAssertEqual(store.period, "2026-11")
        XCTAssertEqual(callsAfterBlockedNext.filter { if case .monthly = $0 { return true }; return false }.count, 1)

        await store.previousMonth()
        XCTAssertEqual(store.period, "2026-10")
        XCTAssertTrue(store.canGoNext)

        await store.nextMonth()
        XCTAssertEqual(store.period, "2026-11")
        XCTAssertFalse(store.canGoNext)
    }

    func testPeriodAndNavigationWithBuddhistDeviceCalendarAndServerCurrentMonth() async throws {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        // Year 2569 in Buddhist calendar == 2026 Gregorian.
        let janDate = try XCTUnwrap(buddhist.date(from: DateComponents(year: 2569, month: 1, day: 15, hour: 12)))

        let mock = MockBudgetAPI(monthly: { period, currency in
            BudgetFixtures.monthly(period: period, currentMonth: "2026-01", currency: currency ?? "PLN")
        })
        let store = BudgetStore(api: mock, now: janDate)
        XCTAssertEqual(store.period, "2026-01")
        XCTAssertFalse(store.canGoNext)

        // Month title must always format the Warsaw Gregorian month regardless of Buddhist locale or west timezone.
        let previousTZ = TimeZone.ReferenceType.default
        TimeZone.ReferenceType.default = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        defer { TimeZone.ReferenceType.default = previousTZ }
        let title = BudgetStore.monthTitle(for: store.monthDate, locale: Locale(identifier: "en_US@calendar=buddhist"))
        XCTAssertEqual(title, "January 2026")

        await store.load()
        await store.previousMonth()
        XCTAssertEqual(store.period, "2025-12")
        XCTAssertTrue(store.canGoNext)

        await store.nextMonth()
        XCTAssertEqual(store.period, "2026-01")
        XCTAssertFalse(store.canGoNext)

        // Server's current_month caps forward navigation even when device clock is ahead.
        let serverAheadOrBehindMock = MockBudgetAPI(monthly: { period, currency in
            BudgetFixtures.monthly(period: period, currentMonth: "2026-10", currency: currency ?? "PLN")
        })
        let cappedStore = BudgetStore(api: serverAheadOrBehindMock, now: now)
        await cappedStore.previousMonth()
        XCTAssertEqual(cappedStore.period, "2026-10")
        XCTAssertEqual(cappedStore.serverCurrentMonth, "2026-10")
        XCTAssertFalse(cappedStore.canGoNext)
        let beforeBlocked = await serverAheadOrBehindMock.calls.count
        await cappedStore.nextMonth()
        let afterBlocked = await serverAheadOrBehindMock.calls.count
        XCTAssertEqual(afterBlocked, beforeBlocked)
    }
}

@MainActor
final class BudgetClientTests: XCTestCase {
    private func pairedClient(
        _ transport: any ClientTransport,
        budgetEnabled: @escaping @Sendable () -> Bool = { true }
    ) throws -> APIClient {
        let store = MemoryDeviceTokenStore(.init(
            server: AppConfig.serverURL, provenance: .legacyPasswordLogin, actor: "u", credential: fakeDeviceToken
        ))
        return APIClient(
            transport: transport,
            receiptPairing: ReceiptPairing(store: store),
            sessionStore: try testCredentialSessionStore(token: "session-token"),
            budgetEnabled: budgetEnabled
        )
    }

    func testMonthlyWireRequestHasPathQueryAndDeviceBearer() async throws {
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.monthlyJSON)
        let api = try pairedClient(transport)

        _ = try await api.monthlyBudget(period: "2026-11", currency: "EUR")

        let request = try XCTUnwrap(transport.last?.request)
        let components = try XCTUnwrap(URLComponents(string: request.path ?? ""))
        XCTAssertEqual(components.path, "/api/budget/analytics/monthly-budget")
        XCTAssertEqual(query(components)["period"], "2026-11")
        XCTAssertEqual(query(components)["currency"], "EUR")
        XCTAssertEqual(request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
        XCTAssertNil(request.headerFields[.cookie])
    }

    func testTransactionsWireRequestHasFiltersCursorAndLimit() async throws {
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.transactionsJSON)
        let api = try pairedClient(transport)

        _ = try await api.transactions(
            period: "2026-10", currency: "PLN", categoryID: "uncategorised",
            cursor: "cursor value", limit: 50
        )

        let request = try XCTUnwrap(transport.last?.request)
        let components = try XCTUnwrap(URLComponents(string: request.path ?? ""))
        XCTAssertEqual(components.path, "/api/budget/analytics/transactions")
        let items = query(components)
        XCTAssertEqual(items["period"], "2026-10")
        XCTAssertEqual(items["currency"], "PLN")
        XCTAssertEqual(items["category_id"], "uncategorised")
        XCTAssertEqual(items["cursor"], "cursor value")
        XCTAssertEqual(items["limit"], "50")
        XCTAssertNil(items["kind"])
        XCTAssertNil(items["query"])
        XCTAssertEqual(request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")
    }

    func testStatusWireRequestAndErrorMapping() async throws {
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.statusJSON)
        let api = try pairedClient(transport)
        _ = try await api.status()
        XCTAssertEqual(transport.last?.request.path, "/api/budget/status")
        XCTAssertEqual(transport.last?.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")

        XCTAssertEqual(BudgetError.from(status: 401), .unauthorized)
        XCTAssertEqual(BudgetError.from(status: 403), .forbidden)
        XCTAssertEqual(BudgetError.from(status: 404), .unavailable)
        XCTAssertEqual(BudgetError.from(status: 503), .unavailable)
        XCTAssertEqual(BudgetError.from(status: 500), .failed)
    }

    func testForbiddenResponseWithEmptyBodyIsMapped() async throws {
        let api = try pairedClient(StubTransport { _ in (403, nil) })
        do {
            _ = try await api.monthlyBudget(period: "2026-11", currency: nil)
            XCTFail("Expected forbidden")
        } catch {
            XCTAssertEqual(error as? BudgetError, .forbidden)
        }
    }

    func testStaleCursor409WireResponseMapsToStaleCursor() async throws {
        let api = try pairedClient(StubTransport { _ in
            (409, Data(#"{"ok":false,"error":"budget_analytics_stale_cursor"}"#.utf8))
        })
        do {
            _ = try await api.transactions(
                period: "2026-11", currency: "PLN", categoryID: nil, cursor: "c1", limit: 50
            )
            XCTFail("Expected staleCursor")
        } catch {
            XCTAssertEqual(error as? BudgetError, .staleCursor)
        }
    }

    func testDispatchGateBlocksAllBudgetMethodsByDefaultAndWhenDisabled() async throws {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.monthlyJSON)
        // Default budgetEnabled must be { false } (production stays off).
        let defaultClient = APIClient(
            transport: transport,
            receiptPairing: ReceiptPairing(store: store),
            sessionStore: try testCredentialSessionStore(token: "session-token")
        )
        let disabledClient = try pairedClient(transport, budgetEnabled: { false })

        for api in [defaultClient, disabledClient] {
            do {
                _ = try await api.monthlyBudget(period: "2026-11", currency: "PLN")
                XCTFail("Expected forbidden")
            } catch {
                XCTAssertEqual(error as? BudgetError, .forbidden)
            }
            do {
                _ = try await api.transactions(period: "2026-11", currency: "PLN", categoryID: nil, cursor: nil, limit: 50)
                XCTFail("Expected forbidden")
            } catch {
                XCTAssertEqual(error as? BudgetError, .forbidden)
            }
            do {
                _ = try await api.status()
                XCTFail("Expected forbidden")
            } catch {
                XCTAssertEqual(error as? BudgetError, .forbidden)
            }
            XCTAssertNil(transport.last)
        }

        final class GateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var enabled = false
            func set(_ value: Bool) { lock.withLock { enabled = value } }
            func get() -> Bool { lock.withLock { enabled } }
        }
        let gate = GateBox()
        let dynamicClient = try pairedClient(transport, budgetEnabled: { gate.get() })
        gate.set(true)
        _ = try await dynamicClient.monthlyBudget(period: "2026-11", currency: "PLN")
        XCTAssertNotNil(transport.last)

        let transportAfter = CapturingTransport(status: 200, body: BudgetMappingTests.monthlyJSON)
        let gatedAgain = try pairedClient(transportAfter, budgetEnabled: { gate.get() })
        gate.set(false)
        do {
            _ = try await gatedAgain.status()
            XCTFail("Expected forbidden")
        } catch {
            XCTAssertEqual(error as? BudgetError, .forbidden)
        }
        XCTAssertNil(transportAfter.last)
    }

    func testDispatchGateBlocksDirectGeneratedClientBudgetCallsWhenDisabled() async throws {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.monthlyJSON)
        // Default budgetEnabled is { false }; calling generated client directly must still block.
        let defaultClient = APIClient(
            transport: transport,
            receiptPairing: ReceiptPairing(store: store),
            sessionStore: try testCredentialSessionStore(token: "session-token")
        )

        let directCalls: [@Sendable () async throws -> Void] = [
            { _ = try await defaultClient.requestClient().getBudgetAnalyticsMonthlyBudget(.init()) },
            { _ = try await defaultClient.requestClient().getBudgetAnalyticsTransactions(.init(query: .init(period: "2026-11"))) },
            { _ = try await defaultClient.requestClient().getBudgetStatus(.init()) },
        ]
        for call in directCalls {
            do {
                try await call()
                XCTFail("Expected forbidden")
            } catch {
                XCTAssertEqual(BudgetError.wrap(error), .forbidden)
                let clientError = try XCTUnwrap(error as? ClientError)
                XCTAssertEqual(clientError.underlyingError as? BudgetError, .forbidden)
            }
            XCTAssertNil(transport.last)
        }
    }

    func testBudget401And403DoNotTouchReceiptPairingOrSession() async throws {
        let deviceStore = MemoryDeviceTokenStore(.init(
            server: AppConfig.serverURL, provenance: .legacyPasswordLogin, actor: "u", credential: fakeDeviceToken
        ))
        let pairing = ReceiptPairing(store: deviceStore)
        let sessionStore = try testCredentialSessionStore(token: "session-token")
        let originalSession = sessionStore.currentSnapshot()

        let mockHestia = MockHestiaAPI()
        await mockHestia.setWhoami(role: "admin")
        await mockHestia.setDiscovery(.init(
            devices: .init(additionalProperties: [:]),
            globals: .init(cribTemp: 21, outdoorHumidity: 50, outdoorTemp: 10),
            irButtons: [],
            klima: .init(file: "k.ir", powerOn: .init(additionalProperties: ["cool": [18, 19, 20]]), presets: ["off"]),
            klimaState: .init(mode: "cool", power: false, temp: 20),
            mode: "standalone",
            ruleVocab: .init(cmpOps: [], conditionTypes: [], frameActionOps: [], modes: [],
                             presenceEvents: [], stateFields: .init(), sunEvents: [], triggerTypes: []),
            summary: .init(confirmed: 0, total: 0, unknown: 0),
            targetMode: "standalone"
        ))
        let app = AppState(
            api: mockHestia,
            receiptPairing: pairing,
            sessionStore: sessionStore,
            events: { _ in AsyncStream { $0.finish() } }
        )
        await app.connect()
        XCTAssertEqual(app.phase, .ready)
        XCTAssertEqual(pairing.status, .paired)

        for (status, body) in [
            (401, #"{"error":{"code":"device_token_expired"}}"#),
            (403, #"{"ok":false,"error":"budget_forbidden"}"#),
        ] {
            let api = APIClient(
                transport: CapturingTransport(status: status, body: body),
                receiptPairing: pairing,
                sessionStore: sessionStore,
                budgetEnabled: { true }
            )
            let expected: BudgetError = status == 401 ? .unauthorized : .forbidden
            let calls: [@Sendable () async throws -> Void] = [
                { _ = try await api.monthlyBudget(period: "2026-11", currency: nil) },
                { _ = try await api.transactions(period: "2026-11", currency: "PLN", categoryID: nil, cursor: nil, limit: 50) },
                { _ = try await api.status() },
            ]
            for call in calls {
                do {
                    try await call()
                    XCTFail("Expected \(expected)")
                } catch {
                    XCTAssertEqual(error as? BudgetError, expected)
                }
            }
            XCTAssertEqual(pairing.status, .paired)
            XCTAssertEqual(deviceStore.load()?.credential, fakeDeviceToken)
            XCTAssertEqual(sessionStore.currentSnapshot(), originalSession)
            XCTAssertEqual(app.phase, .ready)
            XCTAssertEqual(app.whoami?.user, "u")
        }
    }

    private func query(_ components: URLComponents) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }
}

extension MockHestiaAPI: BudgetAPI {
    func monthlyBudget(period: String, currency: String?) async throws -> BudgetMonthly {
        BudgetFixtures.monthly(period: period, currency: currency ?? "PLN")
    }

    func transactions(period: String, currency: String?, categoryID: String?, cursor: String?, limit: Int) async throws -> BudgetTransactionPage {
        BudgetFixtures.page()
    }

    func status() async throws -> BudgetStatus { BudgetFixtures.status }
}

@MainActor
final class BudgetGateTests: XCTestCase {
    private let owner = Capabilities(user: "owner", ownBudget: .init(
        permissions: [.budgetView], canView: true, canUseReceipts: false, canManageDevices: false
    ))

    private func makeApp(_ mock: MockHestiaAPI) -> AppState {
        AppState(
            api: mock,
            receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            events: { AsyncStream { $0.finish() } }
        )
    }

    func testBudgetAPIStaysOffByDefaultWhenAdvertised() async {
        let mock = MockHestiaAPI()
        let app = makeApp(mock)
        await mock.setFeatures([.capabilities, .budgetNativeRead])
        await mock.setCapabilities(owner)
        await app.connect()

        XCTAssertFalse(app.nativeBudgetEnabled)
        XCTAssertEqual(app.serverFeatures?.supports(.budgetNativeRead), true)
        XCTAssertNil(app.budgetAPI)
        XCTAssertNil(app.makeBudgetStore())
    }

    func testBudgetAPIRequiresServerFeatureAndViewGrantWhenFlagIsEnabled() async {
        let mock = MockHestiaAPI()
        let app = makeApp(mock)
        app.nativeBudgetEnabled = true
        await mock.setFeatures([.capabilities])
        await mock.setCapabilities(owner)
        await app.connect()
        XCTAssertNil(app.budgetAPI)

        await mock.setFeatures([.capabilities, .budgetNativeRead])
        await mock.setCapabilities(Capabilities(user: "viewer"))
        await app.refresh()
        XCTAssertNil(app.budgetAPI)

        await mock.setCapabilities(owner)
        await app.refresh()
        XCTAssertNotNil(app.budgetAPI)
    }
}

@MainActor
final class BudgetAuthTests: XCTestCase {
    private let operations = [
        ("getBudgetAnalyticsMonthlyBudget", "/api/budget/analytics/monthly-budget"),
        ("getBudgetAnalyticsTransactions", "/api/budget/analytics/transactions"),
        ("getBudgetStatus", "/api/budget/status"),
    ]

    func testBudgetReadsUseTheDeviceTokenAndNeverTheSessionBearerOrCookie() async throws {
        let server = AppConfig.serverURL
        let store = MemoryDeviceTokenStore(.init(server: server, credential: fakeDeviceToken))
        let middleware = BearerAuthMiddleware(
            session: BoundSession(origin: server, actor: nil, token: "fake-session-token"),
            receiptPairing: ReceiptPairing(store: store),
            budgetEnabled: { true }
        )
        for (operation, path) in operations {
            let transport = CapturingTransport(status: 200, body: "{}")
            var request = HTTPRequest(method: .get, scheme: server.scheme, authority: server.host, path: path)
            request.headerFields[.cookie] = "fake-cookie"
            _ = try await middleware.intercept(request, body: nil, baseURL: server, operationID: operation) { request, body, url in
                try await transport.send(request, body: body, baseURL: url, operationID: operation)
            }
            let sent = try XCTUnwrap(transport.last?.request)
            XCTAssertEqual(sent.headerFields[.authorization], "Bearer fake-device-token", path)
            XCTAssertNil(sent.headerFields[.cookie], path)
        }
    }

    func testBudgetReadsWithoutADeviceTokenSendNothing() async throws {
        let server = AppConfig.serverURL
        let middleware = BearerAuthMiddleware(
            session: BoundSession(origin: server, actor: nil, token: "fake-session-token"),
            receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            budgetEnabled: { true }
        )
        for (operation, path) in operations {
            let transport = CapturingTransport(status: 200, body: "{}")
            let request = HTTPRequest(method: .get, scheme: server.scheme, authority: server.host, path: path)
            do {
                _ = try await middleware.intercept(request, body: nil, baseURL: server, operationID: operation) { request, body, url in
                    try await transport.send(request, body: body, baseURL: url, operationID: operation)
                }
                XCTFail("expected forbidden for \(path)")
            } catch let error as BudgetError {
                XCTAssertEqual(error, .forbidden)
            }
            XCTAssertNil(transport.last, path)
        }
    }

    func testBudgetReadsAreBlockedByMiddlewareWhenDisabled() async throws {
        let server = AppConfig.serverURL
        let store = MemoryDeviceTokenStore(.init(server: server, credential: fakeDeviceToken))
        let middleware = BearerAuthMiddleware(
            session: BoundSession(origin: server, actor: nil, token: "fake-session-token"),
            receiptPairing: ReceiptPairing(store: store)
        )
        for (operation, path) in operations {
            let transport = CapturingTransport(status: 200, body: "{}")
            let request = HTTPRequest(method: .get, scheme: server.scheme, authority: server.host, path: path)
            do {
                _ = try await middleware.intercept(request, body: nil, baseURL: server, operationID: operation) { request, body, url in
                    try await transport.send(request, body: body, baseURL: url, operationID: operation)
                }
                XCTFail("expected forbidden for \(path)")
            } catch let error as BudgetError {
                XCTAssertEqual(error, .forbidden)
            }
            XCTAssertNil(transport.last, path)
        }
    }
}
