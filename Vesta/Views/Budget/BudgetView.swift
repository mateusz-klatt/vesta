import SwiftUI

struct BudgetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let store: BudgetStore
    var onClose: () -> Void = {}
    @State private var shownCategory: BudgetCategory?

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background)
                .navigationTitle("Budget")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            onClose()
                            store.clear()
                            dismiss()
                        }
                    }
                    if store.isRefreshing {
                        ToolbarItem(placement: .primaryAction) { ProgressView() }
                    }
                }
                .task {
                    if !closeIfDenied() {
                        await store.load()
                    }
                }
                .onChange(of: store.isDenied) { _, denied in
                    if denied { closeIfDenied() }
                }
                .navigationDestination(item: $shownCategory) { category in
                    BudgetCategoryTransactionsView(store: store, category: category)
                }
        }
        .privacySensitive()
        .onDisappear {
            onClose()
            store.clear()
        }
    }

    @discardableResult
    func closeIfDenied() -> Bool {
        guard store.isDenied else { return false }
        shownCategory = nil
        onClose()
        dismiss()
        return true
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let overview = store.overview {
                loaded(overview)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .unavailable:
            errorView(store.failure ?? .unavailable)
        case .unauthorized:
            errorView(store.failure ?? .unauthorized)
        case .forbidden:
            errorView(.forbidden)
        case .failed:
            errorView(store.failure ?? .failed)
        }
    }

    private func loaded(_ overview: BudgetMonthly) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                BudgetMonthSwitcher(store: store)
                BudgetSummaryCard(overview: overview)
                if let pace = overview.pace {
                    BudgetPaceCard(pace: pace, currency: overview.currency)
                }
                categories(overview)
                BudgetTransactionsCard(store: store)
                if let dataAsOf = store.dataAsOf {
                    LabeledContent {
                        Text(dataAsOf.formatted(
                            .dateTime.day().month(.abbreviated).year().hour().minute().locale(locale)
                        ))
                    } label: {
                        Text("Data as of")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding()
        }
        .refreshable { await store.refresh() }
    }

    private func categories(_ overview: BudgetMonthly) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Categories").font(.headline)
                Spacer()
                if store.categoryID != nil {
                    Button("Clear category filter") {
                        Task { await store.selectCategory(nil) }
                    }
                    .font(.caption)
                }
            }
            if overview.categories.isEmpty {
                Text("No categories").foregroundStyle(Theme.textSecondary)
            }
            ForEach(overview.categories) { category in
                if category.isOneOff {
                    BudgetCategoryRow(category: category, currency: overview.currency)
                } else {
                    Button {
                        shownCategory = category
                        Task { await store.selectCategory(category.id) }
                    } label: {
                        BudgetCategoryRow(category: category, currency: overview.currency)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vestaCard()
    }

    private func errorView(_ error: BudgetError) -> some View {
        BudgetErrorView(error: error) { Task { await store.load() } }
    }
}

private struct BudgetErrorView: View {
    let error: BudgetError
    let retry: () -> Void

    private var isDenied: Bool { error == .forbidden || error == .unauthorized }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(error.title)
            } icon: {
                Image(systemName: isDenied ? "lock.fill" : "exclamationmark.triangle")
            }
        } description: {
            Text(error.message)
        } actions: {
            if !isDenied {
                Button("Try again", action: retry)
            }
        }
    }
}

private struct BudgetMonthSwitcher: View {
    @Environment(\.locale) private var locale
    let store: BudgetStore

    var body: some View {
        HStack {
            Button { Task { await store.previousMonth() } } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous month")
            Text(verbatim: BudgetStore.monthTitle(for: store.monthDate, locale: locale))
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
            Button { Task { await store.nextMonth() } } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next month")
            .disabled(!store.canGoNext)
            if store.availableCurrencies.count > 1 {
                Menu {
                    ForEach(store.availableCurrencies, id: \.self) { code in
                        Button {
                            Task { await store.selectCurrency(code) }
                        } label: {
                            if code == store.currency {
                                Label(code, systemImage: "checkmark")
                            } else {
                                Text(verbatim: code)
                            }
                        }
                    }
                } label: {
                    Text(verbatim: store.currency ?? "—")
                        .font(.subheadline.weight(.medium))
                }
                .accessibilityLabel("Currency")
            }
        }
    }
}

private struct BudgetSummaryCard: View {
    @Environment(\.locale) private var locale
    let overview: BudgetMonthly

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = overview.summary {
                HStack(alignment: .top, spacing: 12) {
                    metric("Spent", amount: summary.spent)
                    metric("Budget", amount: summary.startBudget)
                    metric("Remaining", amount: summary.remaining, isOver: summary.remaining < 0)
                }
            } else {
                Text("No budget configured for this month.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vestaCard()
    }

    private func metric(_ title: LocalizedStringResource, amount: Decimal, isOver: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            Text(verbatim: amount.formatted(.currency(code: overview.currency).locale(locale)))
                .font(.headline)
                .foregroundStyle(isOver ? Color.red : Theme.textPrimary)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BudgetPaceCard: View {
    @Environment(\.locale) private var locale
    let pace: BudgetPace
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(status)
            } label: {
                Text("Pace")
            }
            if let projected = pace.projectedMonthSpend {
                LabeledContent("Projected month spend") {
                    Text(verbatim: projected.formatted(.currency(code: currency).locale(locale)))
                }
            }
            if let day = pace.exhaustionDay {
                LabeledContent("Budget runs out on day", value: String(day))
            }
        }
        .font(.subheadline)
        .vestaCard()
    }

    private var status: LocalizedStringResource {
        switch pace.status {
        case .historical: "Previous month"
        case .noBudget: "No budget"
        case .alreadyReached: "Budget reached"
        case .noPositivePace: "No spending pace"
        case .runsOut: "Over budget pace"
        case .withinBudget: "Within budget"
        }
    }
}

private struct BudgetCategoryRow: View {
    @Environment(\.locale) private var locale
    let category: BudgetCategory
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if let name = category.name { Text(verbatim: name) }
                    else { Text("Uncategorised") }
                }
                .foregroundStyle(Theme.textPrimary)
                Spacer()
                if !category.isOneOff {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Text(verbatim: category.netSpending.formatted(.currency(code: currency).locale(locale)))
                if let limit = category.limit {
                    Text(verbatim: "/ \(limit.monthlyLimit.formatted(.currency(code: currency).locale(locale)))")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(verbatim: "\(percent(limit))%")
                        .foregroundStyle(limit.isOver ? Color.red : Theme.textSecondary)
                } else {
                    Spacer()
                    Text("No limit").foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.subheadline)
            if let limit = category.limit {
                ProgressView(value: progress(limit), total: 100)
                    .tint(limit.isOver ? .red : Theme.accent)
                    .accessibilityLabel("Budget used")
            }
        }
    }

    private func percent(_ limit: BudgetCategoryLimit) -> Int {
        NSDecimalNumber(decimal: limit.percentUsedFloor).intValue
    }

    private func progress(_ limit: BudgetCategoryLimit) -> Double {
        min(100, max(0, NSDecimalNumber(decimal: limit.percentUsedFloor).doubleValue))
    }
}

private struct BudgetTransactionsCard: View {
    let store: BudgetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transactions").font(.headline)
                Spacer()
                Text(verbatim: "\(store.filteredTotal)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            BudgetTransactionRows(store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vestaCard()
    }
}

private struct BudgetCategoryTransactionsView: View {
    let store: BudgetStore
    let category: BudgetCategory

    var body: some View {
        Group {
            switch store.state {
            case .unauthorized:
                BudgetErrorView(error: store.failure ?? .unauthorized) { Task { await store.load() } }
            case .forbidden:
                BudgetErrorView(error: .forbidden) { Task { await store.load() } }
            case .unavailable:
                BudgetErrorView(error: store.failure ?? .unavailable) { Task { await store.load() } }
            case .failed:
                BudgetErrorView(error: store.failure ?? .failed) { Task { await store.load() } }
            case .loading, .loaded:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if store.isLoading && store.transactions.isEmpty {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            BudgetTransactionRows(store: store)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(category.name.map { Text(verbatim: $0) } ?? Text("Uncategorised"))
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
    }
}

private struct BudgetTransactionRows: View {
    let store: BudgetStore

    var body: some View {
        if store.transactions.isEmpty && !store.isLoading {
            Text("No transactions").foregroundStyle(Theme.textSecondary)
        }
        ForEach(store.transactions) { transaction in
            BudgetTransactionRow(transaction: transaction)
            if transaction.id != store.transactions.last?.id { Divider() }
        }
        if store.nextCursor != nil {
            Button { Task { await store.loadMore() } } label: {
                if store.isLoadingMore { ProgressView() }
                else { Text("Load more") }
            }
            .disabled(store.isLoading || store.isLoadingMore)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct BudgetTransactionRow: View {
    @Environment(\.locale) private var locale
    let transaction: BudgetTransaction

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let title = transaction.payee ?? transaction.details {
                    Text(verbatim: title)
                } else {
                    Text("Transaction")
                }
                if transaction.payee != nil, let details = transaction.details {
                    Text(verbatim: details).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if let date = transaction.bookingDate {
                    Text(verbatim: date).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Text(verbatim: amount)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(transaction.isCredit ? Color.green : Theme.textPrimary)
        }
    }

    private var amount: String {
        let value = transaction.signedAmount.formatted(.currency(code: transaction.currency).locale(locale))
        return transaction.isCredit ? "+\(value)" : value
    }
}
