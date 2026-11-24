import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

private enum BudgetFixtures {
    static func monthly(period: String = "2026-11", currency: String = "PLN") -> BudgetMonthly {
        BudgetMonthly(
            period: period,
            currency: currency,
            availableCurrencies: ["PLN", "EUR"],
            summary: BudgetSummary(startBudget: 2_000, spent: 500, remaining: 1_500),
            pace: nil,
            categories: []
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
        XCTAssertEqual(monthly.currency, "PLN")
        XCTAssertEqual(monthly.availableCurrencies, ["PLN", "EUR"])
        XCTAssertEqual(monthly.summary?.startBudget, Decimal(string: "10000.123456789012345678"))
        XCTAssertEqual(monthly.summary?.spent, Decimal(string: "2345.67"))
        XCTAssertEqual(monthly.pace?.status, .runsOut)
        XCTAssertEqual(monthly.pace?.projectedMonthSpend, Decimal(string: "2250.0625"))
        XCTAssertEqual(monthly.pace?.exhaustionDay, 26)
        XCTAssertEqual(monthly.categories.count, 2)
        XCTAssertEqual(monthly.categories[0].name, "Weekly food")
        XCTAssertEqual(monthly.categories[0].limit?.monthlyLimit, Decimal(string: "960.08"))
        XCTAssertEqual(monthly.categories[0].limit?.percentUsedFloor, Decimal(string: "125.9"))
        XCTAssertTrue(monthly.categories[0].limit?.isOver == true)
        XCTAssertNil(monthly.categories[1].categoryID)
        XCTAssertNil(monthly.categories[1].name)
        XCTAssertNil(monthly.categories[1].limit)
        XCTAssertEqual(monthly.categories[1].id, "uncategorised")
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
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date { Date(timeIntervalSince1970: 1_795_557_600) }

    private func store(_ api: any BudgetAPI) -> BudgetStore {
        BudgetStore(api: api, now: now, calendar: calendar)
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
        XCTAssertEqual(store.dataAsOf, Date(timeIntervalSince1970: 300))
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.monthly("2026-11", nil)))
        XCTAssertTrue(calls.contains(.transactions("2026-11", nil, nil, nil, 50)))
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
}

@MainActor
final class BudgetClientTests: XCTestCase {
    private func pairedClient(_ transport: any ClientTransport) -> APIClient {
        let store = MemoryDeviceTokenStore(.init(server: AppConfig.serverURL, credential: fakeDeviceToken))
        return APIClient(transport: transport, receiptPairing: ReceiptPairing(store: store), sessionToken: { "session-token" })
    }

    func testMonthlyWireRequestHasPathQueryAndDeviceBearer() async throws {
        let transport = CapturingTransport(status: 200, body: BudgetMappingTests.monthlyJSON)
        let api = pairedClient(transport)

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
        let api = pairedClient(transport)

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
        let api = pairedClient(transport)
        _ = try await api.status()
        XCTAssertEqual(transport.last?.request.path, "/api/budget/status")
        XCTAssertEqual(transport.last?.request.headerFields[.authorization], "Bearer \(fakeDeviceToken.token)")

        XCTAssertEqual(BudgetError.from(status: 401), .unauthorized)
        XCTAssertEqual(BudgetError.from(status: 403), .forbidden)
        XCTAssertEqual(BudgetError.from(status: 404), .unavailable)
        XCTAssertEqual(BudgetError.from(status: 503), .unavailable)
        XCTAssertEqual(BudgetError.from(status: 500), .failed)
    }

    func testForbiddenResponseWithEmptyBodyIsMapped() async {
        let api = pairedClient(StubTransport { _ in (403, nil) })
        do {
            _ = try await api.monthlyBudget(period: "2026-11", currency: nil)
            XCTFail("Expected forbidden")
        } catch {
            XCTAssertEqual(error as? BudgetError, .forbidden)
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
    func testBudgetAPIIsHiddenByDefaultEvenForAdmin() async {
        let mock = MockHestiaAPI()
        let app = AppState(
            api: mock,
            receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            events: { AsyncStream { $0.finish() } }
        )
        await mock.setWhoami(role: "admin")
        await app.connect()
        XCTAssertNil(app.budgetAPI)
    }

    func testBudgetAPIIsNilForNonAdminAndAvailableForAdmin() async {
        let mock = MockHestiaAPI()
        let app = AppState(
            api: mock,
            receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()),
            events: { AsyncStream { $0.finish() } }
        )
        app.nativeBudgetEnabled = true
        await mock.setWhoami(role: "viewer")
        await app.connect()
        XCTAssertNil(app.budgetAPI)

        await mock.setWhoami(role: "admin")
        await app.connect()
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
        let middleware = BearerAuthMiddleware(token: { "fake-session-token" }, receiptPairing: ReceiptPairing(store: store))
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
        let middleware = BearerAuthMiddleware(token: { "fake-session-token" },
                                              receiptPairing: ReceiptPairing(store: MemoryDeviceTokenStore()))
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
