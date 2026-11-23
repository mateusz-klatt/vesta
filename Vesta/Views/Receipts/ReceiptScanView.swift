import PhotosUI
import SwiftUI

/// Add a paper receipt to hestia's budget: scan (or pick a photo, or paste Live
/// Text) → check the recognised text → review what hestia parsed → confirm.
/// Only the redacted text is sent; the photo never leaves the phone.
struct ReceiptScanView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showPairing = false
    /// Owned by the presenter, which calls ``ReceiptFlow/abandon()`` when the sheet closes.
    let flow: ReceiptFlow

    var body: some View {
        NavigationStack {
            Group {
                switch flow.step {
                case .capture: ReceiptCaptureStep(flow: flow)
                case .edit: ReceiptEditStep(flow: flow)
                case .review: ReceiptReviewStep(flow: flow)
                case .done: ReceiptDoneStep { dismiss() }
                }
            }
            .disabled(flow.isBusy)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if flow.step != .done {
                        Button("Cancel") { dismiss() }
                            .disabled(flow.isBusy)
                    }
                }
                if flow.step != .done && (flow.error == .pairAgain || app.receiptPairing.status == .pairAgain) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Pair again") { showPairing = true }
                            .disabled(flow.isBusy)
                    }
                }
            }
            .overlay {
                if flow.isBusy { ProgressView().controlSize(.large) }
            }
        }
        // Cleanup runs on any dismissal; this only guards review edits from a stray swipe.
        .interactiveDismissDisabled(flow.step == .review)
        .sheet(isPresented: $showPairing, onDismiss: {
            if app.receiptPairing.status == .paired && flow.error == .pairAgain { flow.error = nil }
        }) {
            ReceiptPairingView().appLanguage(app.appLanguage)
        }
    }
}

// MARK: - Steps

private struct ReceiptCaptureStep: View {
    @Bindable var flow: ReceiptFlow
    @State private var showScanner = false
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                if DocumentScanner.isSupported {
                    Button { showScanner = true } label: {
                        Label("Scan receipt", systemImage: "doc.viewfinder")
                    }
                }
                PhotosPicker(selection: $photo, matching: .images) {
                    Label("Choose a photo", systemImage: "photo")
                }
                Button {
                    flow.useText(UIPasteboard.general.string ?? "")
                } label: {
                    Label("Paste text", systemImage: "doc.on.clipboard")
                }
            } footer: {
                Text("Text is read on this iPhone. Only the text is sent to your server, with card numbers removed. The photo is not saved or uploaded.")
            }
            ReceiptErrorSection(error: flow.error)
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner(
                onFinish: { pages in
                    showScanner = false
                    Task { await flow.recognize(pages) }
                },
                onCancel: { showScanner = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task {
                await flow.recognize {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)?.cgImage else { return [] }
                    return [image]
                }
            }
        }
    }
}

private struct ReceiptEditStep: View {
    @Bindable var flow: ReceiptFlow

    var body: some View {
        Form {
            Section {
                TextEditor(text: $flow.text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Recognised text")
            } footer: {
                if !VisionReceiptRecognizer.supportsPolish {
                    Text("This iPhone can’t read Polish characters yet — check ą, ę, ł, ż in product names.")
                } else {
                    Text("Fix anything misread, then send it to your server to read the receipt.")
                }
            }
            ReceiptErrorSection(error: flow.error)
            Section {
                Button("Read receipt") { Task { await flow.send() } }
                    .disabled(flow.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Start over", role: .destructive) { flow.startOver() }
            }
        }
    }
}

private struct ReceiptReviewStep: View {
    @Bindable var flow: ReceiptFlow

    var body: some View {
        Form {
            Section("Receipt") {
                TextField("Shop", text: $flow.form.shopName)
                    .onSubmit { flow.form.shopName = PANRedactor.redact(flow.form.shopName) }
                TextField("NIP", text: $flow.form.nip).keyboardType(.numberPad)
                if flow.form.day != nil {
                    DatePicker("Date", selection: dayBinding, displayedComponents: .date)
                } else {
                    Button("Set date") { flow.form.day = ReceiptDay(date: .now) }
                        .foregroundStyle(.red)
                }
                TextField("Time (HH:MM)", text: $flow.form.time).keyboardType(.numbersAndPunctuation)
                Picker("Type", selection: $flow.form.kind) {
                    Text("Purchase").tag(ReceiptConfirmRequest.ReceiptKindPayload.purchase)
                    Text("Refund").tag(ReceiptConfirmRequest.ReceiptKindPayload.refund)
                }
                Picker("Payment", selection: $flow.form.payment) {
                    Text("Card").tag(ReceiptConfirmRequest.PaymentMethodPayload.card)
                    Text("BLIK").tag(ReceiptConfirmRequest.PaymentMethodPayload.blik)
                    Text("Cash").tag(ReceiptConfirmRequest.PaymentMethodPayload.cash)
                    Text("Mixed").tag(ReceiptConfirmRequest.PaymentMethodPayload.mixed)
                    Text("Unknown").tag(ReceiptConfirmRequest.PaymentMethodPayload.unknown)
                }
                LabeledContent("Total") {
                    TextField("0.00", text: $flow.form.total)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text(verbatim: flow.form.currency).foregroundStyle(Theme.textSecondary)
                }
            }

            Section {
                ForEach(flow.form.lines, id: \.lineNo) { line in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: line.rawName)
                            Text(verbatim: "\(line.quantity) × \(line.unitPriceRaw ?? "—")")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(verbatim: line.netLineTotal).monospacedDigit()
                    }
                }
            } header: {
                Text("Items (\(flow.form.lines.count))")
            } footer: {
                if let delta = flow.form.mismatch {
                    Text("Items and total differ by \(delta.formatted()). Go back and fix the text.")
                        .foregroundStyle(.red)
                } else if !flow.form.invalidLines.isEmpty {
                    Text("Some item amounts don’t add up. Go back and fix the text.")
                        .foregroundStyle(.red)
                }
            }

            if flow.form.canLink {
                Section {
                    if flow.form.matchFieldsEdited {
                        Text("Shop or NIP changed, so these matches no longer apply. Save without a link, or go back and read the text again.")
                            .font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Picker("Bank transaction", selection: $flow.form.candidate) {
                            Text("Don’t link").tag(ReceiptForm.CandidateID?.none)
                            ForEach(flow.candidates, id: \.candidateToken) { candidate in
                                Text(verbatim: Self.describe(candidate))
                                    .tag(ReceiptForm.CandidateID?.some(.init(candidate)))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                } header: {
                    Text("Bank transaction")
                } footer: {
                    if flow.candidates.isEmpty {
                        Text("No matching transaction yet. You can save the receipt without one.")
                    }
                }
            }

            ReceiptErrorSection(error: flow.error)

            Section {
                Button("Save receipt") { Task { await flow.confirm() } }
                    .disabled(!flow.form.isValid)
                Button("Back to text") { Task { await flow.backToEdit() } }
            }
        }
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { flow.form.day?.date ?? .now },
            set: { flow.form.day = ReceiptDay(date: $0) }
        )
    }

    private static func describe(_ candidate: ReceiptCandidate) -> String {
        let day = candidate.transactionDate ?? candidate.bookingDate ?? candidate.valueDate ?? "—"
        let merchant = candidate.merchantTokenHit ? " ✓" : ""
        return "\(day) · \(candidate.amount) \(candidate.currency)\(merchant)"
    }
}

private struct ReceiptDoneStep: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Receipt saved").font(.title2.bold())
            Button("Done", action: close).buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReceiptErrorSection: View {
    let error: ReceiptError?

    var body: some View {
        if let error {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.title).font(.headline)
                    Text(error.message).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    if let technical = error.technical {
                        Text(verbatim: technical).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
