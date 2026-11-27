import SwiftUI

struct ReceiptReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReceiptReviewStore
    var onClose: () -> Void = {}
    @State private var shownReceipt: ImportedReceiptSummary?

    var body: some View {
        NavigationStack {
            content
                .background(Theme.background)
                .navigationTitle("Receipts")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            onClose()
                            store.clear()
                            dismiss()
                        }
                    }
                    if store.isBusy {
                        ToolbarItem(placement: .primaryAction) { ProgressView() }
                    }
                }
                .task { await store.load() }
                .navigationDestination(item: $shownReceipt) { receipt in
                    ImportedReceiptDetailView(store: store, summary: receipt)
                }
        }
        .privacySensitive()
        .sheet(isPresented: Binding(get: { store.groupID != nil }, set: { if !$0 { store.dismissGroup() } })) {
            ReceiptGroupSheet(store: store)
        }
        .onDisappear {
            onClose()
            store.clear()
        }
    }

    @ViewBuilder private var content: some View {
        switch store.state {
        case .loading where store.receipts.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded, .loading, .failed:
            list
        case .unauthorized:
            ReceiptReviewErrorView(error: store.failure ?? .api(.unauthorized))
        case .forbidden:
            ReceiptReviewErrorView(error: .forbidden)
        }
    }

    private var list: some View {
        let receiptsByGroup = Dictionary(grouping: store.receipts) { $0.linkGroup?.groupId }
        return List {
            if let failure = store.failure {
                Section {
                    ReceiptReviewErrorView(error: failure) { Task { await store.load() } }
                }
            }
            if store.receipts.isEmpty, !store.isBusy {
                ContentUnavailableView("No imported receipts", systemImage: "tray")
                    .listRowBackground(Color.clear)
            }
            ForEach(store.groups) { group in
                Section {
                    ForEach(group.receipts) { receipt in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                shownReceipt = receipt
                                Task { await store.select(receipt) }
                            } label: {
                                ImportedReceiptRow(receipt: receipt)
                            }
                            .buttonStyle(.plain)
                            .disabled(store.isBusy)
                            if let badge = ReceiptGroupBadgeContent(group: receipt.linkGroup,
                                                                   members: receiptsByGroup[receipt.linkGroup?.groupId] ?? []) {
                                ReceiptGroupBadge(content: badge, store: store)
                            }
                        }
                    }
                } header: {
                    HStack {
                        if let name = group.name { Text(verbatim: name) }
                        else { Text("Unknown merchant") }
                        Spacer()
                        if group.canConfirmWithoutLinking {
                            Button("Confirm all without linking") {
                                Task { await store.confirmMerchant(group) }
                            }
                            .font(.caption)
                            .disabled(store.isBusy)
                        }
                    }
                }
            }
            if !store.outcomes.isEmpty {
                Section("Receipts") {
                    ForEach(store.outcomes) { outcome in
                        ReceiptConfirmationOutcomeRow(outcome: outcome)
                    }
                }
            }
        }
        .refreshable { await store.load() }
    }
}

private struct ImportedReceiptRow: View {
    @Environment(\.locale) private var locale
    let receipt: ImportedReceiptSummary

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let date = receipt.receiptDate ?? receipt.dueDate {
                    Text(verbatim: date).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if let number = receipt.invoiceNumber {
                    Text(verbatim: number).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                ReceiptHints(gatewayStatus: receipt.gatewayStatus?.rawValue, payeeHost: receipt.payeeHost,
                             hasDocument: receipt.hasDocument)
            }
            Spacer()
            if let amount = receipt.totalAmount {
                Text(verbatim: receiptAmountText(amount, currency: receipt.currency, locale: locale))
                    .font(.subheadline.weight(.medium))
            }
        }
        .foregroundStyle(Theme.textPrimary)
    }
}

private struct ImportedReceiptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReceiptReviewStore
    let summary: ImportedReceiptSummary

    var body: some View {
        let loadedSummary = store.detail?.summary
        let detail = loadedSummary?.receiptId == summary.receiptId ? loadedSummary : nil
        let group = detail == nil ? summary.linkGroup : detail?.linkGroup
        let groupMembers = group.map { group in store.receipts.filter { $0.linkGroup?.groupId == group.groupId } } ?? []
        let pendingSummary = group != nil && store.failure == nil ? summary : nil
        List {
            if !store.isCleared, let displayed = detail ?? pendingSummary {
                Section("Receipt") {
                    if let shop = displayed.rawShopName { LabeledContent("Shop", value: shop) }
                    if let date = displayed.receiptDate ?? displayed.dueDate { LabeledContent("Date", value: date) }
                    if let total = displayed.totalAmount {
                        LabeledContent("Total", value: [total, displayed.currency].compactMap { $0 }.joined(separator: " "))
                    }
                    if let number = displayed.invoiceNumber { LabeledContent("Receipt", value: number) }
                    ReceiptHints(gatewayStatus: displayed.gatewayStatus?.rawValue, payeeHost: displayed.payeeHost,
                                 hasDocument: displayed.hasDocument)
                    if let badge = ReceiptGroupBadgeContent(group: group, members: groupMembers) {
                        ReceiptGroupBadge(content: badge, store: store)
                    }
                }
                if group == nil, summary.linkGroup == nil {
                    transactionSection
                    confirmationSection
                }
            } else if store.isBusy {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let failure = store.failure {
                Section {
                    Text(failure.message).foregroundStyle(Theme.textSecondary)
                    Text(verbatim: failure.reviewCode).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle(store.isCleared ? Text("Receipt") : summary.rawShopName.map { Text(verbatim: $0) } ?? Text("Receipt"))
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .onChange(of: store.confirmedReceiptID) { _, confirmed in
            if confirmed == summary.receiptId { dismiss() }
        }
    }

    private var transactionSection: some View {
        Section("Transaction") {
            if store.canMatchReceipts {
                ForEach(store.candidates, id: \.self) { candidate in
                    Button { store.selectCandidate(candidate) } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: candidate.bookingDate ?? candidate.transactionDate ?? "—")
                                Text(verbatim: "\(candidate.amount) \(candidate.currency)")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if store.selectedCandidate == ReceiptForm.CandidateID(candidate) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)
                }
            } else {
                Text("No matching transaction yet. You can save the receipt without one.")
                    .foregroundStyle(Theme.textSecondary)
            }
            Button { store.selectCandidate(nil) } label: {
                HStack {
                    Text("Don’t link")
                    Spacer()
                    if store.selectedCandidate == nil && (store.hasLinkChoice || store.candidates.isEmpty) {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                    }
                }
            }
            .disabled(store.isBusy || !store.canMatchReceipts)
        }
    }

    private var confirmationSection: some View {
        Section {
            if let error = store.confirmLineError {
                Text(error.title)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else if let adjustment = store.totalAdjustment {
                Text(adjustment.message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button("Save receipt") { Task { await store.confirmSelected() } }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canConfirmSelected)
                .frame(maxWidth: .infinity)
        }
    }
}

struct ReceiptGroupBadgeContent: Equatable {
    let groupID: String
    let memberCount: Int
    let total: ReceiptGroupTotal?

    init?(group: ReceiptLinkGroupRefWire?, members: [ImportedReceiptSummary]) {
        guard let group else { return nil }
        groupID = group.groupId
        memberCount = group.memberCount
        let currentMembers = members.filter {
            $0.linkGroup?.groupId == group.groupId && $0.linkGroup?.groupVersion == group.groupVersion
        }
        total = ReceiptGroupTotal(group: group, members: currentMembers)
    }
}

struct ReceiptGroupTotal: Equatable {
    let amount: Decimal
    let currency: String

    init?(group: ReceiptLinkGroupRefWire, members: [ImportedReceiptSummary]) {
        let receipts = members.filter { $0.receiptId != group.evidenceReceiptId }
        guard receipts.count == group.memberCount, Set(receipts.map(\.receiptId)).count == receipts.count,
              let currency = receipts.first?.currency, currency.wholeMatch(of: /[A-Z]{3}/) != nil else { return nil }
        let posix = Locale(identifier: "en_US_POSIX")
        var sum = Decimal.zero
        for receipt in receipts {
            guard receipt.currency == currency, let total = receipt.totalAmount,
                  total.wholeMatch(of: /[0-9]+(?:\.[0-9]+)?/) != nil,
                  let amount = Decimal(string: total, locale: posix) else { return nil }
            sum += receipt.receiptKind == .refund ? -amount : amount
        }
        guard !sum.isNaN else { return nil }
        self.amount = sum
        self.currency = currency
    }

    func formatted(in locale: Locale) -> String {
        amount.formatted(.currency(code: currency).locale(locale))
    }
}

struct ReceiptGroupSheetContent {
    struct Receipt: Identifiable, Equatable {
        let id: String
        let shop: String?
        let date: String?
        let total: String?
        let currency: String?

        init(_ receipt: ImportedReceiptSummary) {
            id = receipt.receiptId
            shop = receipt.rawShopName
            date = receipt.receiptDate ?? receipt.dueDate
            total = receipt.totalAmount
            currency = receipt.currency
        }
    }

    let transactionReference: String?
    let memberCount: Int
    let total: ReceiptGroupTotal?
    let members: [Receipt]
    let evidence: Receipt?

    init(_ detail: BudgetReceiptGroupDetailResultWire) {
        transactionReference = detail.linkedEntryRef
        memberCount = detail.group.memberCount
        total = ReceiptGroupTotal(group: detail.group, members: detail.members)
        members = detail.members.map(Receipt.init)
        evidence = detail.evidence.map(Receipt.init)
    }
}

private struct ReceiptGroupBadge: View {
    @Environment(\.locale) private var locale
    let content: ReceiptGroupBadgeContent
    let store: ReceiptReviewStore

    var body: some View {
        Button {
            Task { await store.loadGroup(id: content.groupID) }
        } label: {
            HStack(spacing: 8) {
                Label("In group", systemImage: "link")
                Label {
                    Text(content.memberCount, format: .number)
                } icon: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Receipts")
                .accessibilityValue(Text(content.memberCount, format: .number))
                if let total = content.total {
                    let amount = total.formatted(in: locale)
                    Text(verbatim: amount)
                        .accessibilityLabel("Total")
                        .accessibilityValue(Text(verbatim: amount))
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(store.isBusy)
    }
}

private struct ReceiptGroupSheet: View {
    @Environment(\.locale) private var locale
    let store: ReceiptReviewStore

    var body: some View {
        NavigationStack {
            Group {
                if let detail = store.groupDetail {
                    groupList(ReceiptGroupSheetContent(detail))
                } else if let failure = store.groupFailure, let id = store.groupID {
                    ReceiptReviewErrorView(error: failure) { Task { await store.loadGroup(id: id) } }
                } else if store.groupID != nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Theme.background)
            .navigationTitle("Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { store.dismissGroup() }
                }
            }
        }
        .privacySensitive()
    }

    private func groupList(_ content: ReceiptGroupSheetContent) -> some View {
        List {
            Section("Bank transaction") {
                Text("Transaction details unavailable")
                    .foregroundStyle(Theme.textSecondary)
                if let reference = content.transactionReference {
                    DisclosureGroup("Technical details") {
                        Text(verbatim: reference).font(.caption.monospaced())
                    }
                }
            }
            Section {
                LabeledContent("Receipts", value: content.memberCount.formatted(.number.locale(locale)))
                if let total = content.total { LabeledContent("Total", value: total.formatted(in: locale)) }
                ForEach(content.members) { receipt in
                    receiptRow(receipt)
                }
            } header: {
                Text("Receipts")
            }
            if let evidence = content.evidence {
                Section("Payment evidence") { receiptRow(evidence) }
            }
        }
    }

    private func receiptRow(_ receipt: ReceiptGroupSheetContent.Receipt) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if let shop = receipt.shop { Text(verbatim: shop) }
                else { Text("Unknown merchant") }
                if let date = receipt.date {
                    Text(verbatim: date).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if let amount = receipt.total {
                Text(verbatim: receiptAmountText(amount, currency: receipt.currency, locale: locale))
                    .font(.subheadline.weight(.medium))
            }
        }
    }
}

private func receiptAmountText(_ amount: String, currency: String?, locale: Locale) -> String {
    guard let currency, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
        return [amount, currency].compactMap { $0 }.joined(separator: " ")
    }
    return value.formatted(.currency(code: currency).locale(locale))
}

private struct ReceiptHints: View {
    let gatewayStatus: String?
    let payeeHost: String?
    let hasDocument: Bool?

    var body: some View {
        if let gatewayStatus {
            LabeledContent("Payment", value: gatewayStatus)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        if hasDocument == false, let payeeHost {
            Text("Payment without a document — download it from \(payeeHost)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        } else if let payeeHost {
            Text(verbatim: payeeHost)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ReceiptConfirmationOutcomeRow: View {
    let outcome: ReceiptConfirmationOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = outcome.receipt.rawShopName { Text(verbatim: name) }
            else { Text("Receipt") }
            if let error = outcome.error {
                Text(error.message).font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                Text("Receipt saved").font(.caption).foregroundStyle(Theme.textSecondary)
                if let adjustment = outcome.adjustment {
                    Text(adjustment.message).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Text(verbatim: outcome.code).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ReceiptReviewErrorView: View {
    let error: ReceiptError
    var retry: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: error.isAccessDenial ? "lock.fill" : "exclamationmark.triangle")
        } description: {
            Text(error.message)
        } actions: {
            if let retry, !error.isAccessDenial {
                Button("Try again", action: retry)
            }
        }
    }
}
