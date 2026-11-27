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
        List {
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
                        Button {
                            shownReceipt = receipt
                            Task { await store.select(receipt) }
                        } label: {
                            ImportedReceiptRow(receipt: receipt)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isBusy)
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
                Text(verbatim: amountText(amount, currency: receipt.currency))
                    .font(.subheadline.weight(.medium))
            }
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private func amountText(_ amount: String, currency: String?) -> String {
        guard let currency, let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else {
            return [amount, currency].compactMap { $0 }.joined(separator: " ")
        }
        return value.formatted(.currency(code: currency).locale(locale))
    }
}

private struct ImportedReceiptDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReceiptReviewStore
    let summary: ImportedReceiptSummary

    var body: some View {
        List {
            if let detail = store.detail?.summary, detail.receiptId == summary.receiptId {
                Section("Receipt") {
                    if let shop = detail.rawShopName { LabeledContent("Shop", value: shop) }
                    if let date = detail.receiptDate ?? detail.dueDate { LabeledContent("Date", value: date) }
                    if let total = detail.totalAmount {
                        LabeledContent("Total", value: [total, detail.currency].compactMap { $0 }.joined(separator: " "))
                    }
                    if let number = detail.invoiceNumber { LabeledContent("Receipt", value: number) }
                    ReceiptHints(gatewayStatus: detail.gatewayStatus?.rawValue, payeeHost: detail.payeeHost,
                                 hasDocument: detail.hasDocument)
                }
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
        .navigationTitle(summary.rawShopName.map { Text(verbatim: $0) } ?? Text("Receipt"))
        .navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .onChange(of: store.confirmedReceiptID) { _, confirmed in
            if confirmed == summary.receiptId { dismiss() }
        }
    }
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
