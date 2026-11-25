import SwiftUI

@MainActor
struct ReceiptPairingPresentation {
    private var presentedAt: Int?

    mutating func present(in app: AppState) {
        guard app.receiptsAPI != nil else { return }
        presentedAt = app.receiptAccessGeneration
    }

    func isPresented(accessGeneration: Int) -> Bool {
        presentedAt == accessGeneration
    }

    mutating func dismiss(accessGeneration: Int) {
        if isPresented(accessGeneration: accessGeneration) { presentedAt = nil }
    }
}

extension View {
    func receiptPairingSheet(_ presentation: Binding<ReceiptPairingPresentation>, app: AppState,
                             onDismiss: (() -> Void)? = nil) -> some View {
        let generation = app.receiptAccessGeneration
        let isPresented = Binding(
            get: { presentation.wrappedValue.isPresented(accessGeneration: generation) },
            set: { if !$0 { presentation.wrappedValue.dismiss(accessGeneration: generation) } }
        )
        return sheet(isPresented: isPresented, onDismiss: onDismiss) {
            ReceiptPairingView().appLanguage(app.appLanguage)
        }
    }
}

struct ReceiptPairingView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message: LocalizedStringResource?
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    if QRScannerView.isSupported {
                        Button { showScanner = true } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                        }
                    }
                } footer: {
                    Text("In hestia, choose Add device to get a one-time pairing code.")
                }
                if let message = message ?? app.receiptPairing.pairingNotice {
                    Text(message).foregroundStyle(Theme.textSecondary)
                }
                Section {
                    Button("Pair iPhone") { submit() }
                        .disabled(code.isEmpty)
                }
            }
            .disabled(app.receiptPairing.isBusy)
            .overlay {
                if app.receiptPairing.isBusy { ProgressView() }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(app.receiptPairing.status == .pairAgain ? Text("Pair again") : Text("Pair iPhone"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(app.receiptPairing.isBusy)
                }
            }
        }
        .interactiveDismissDisabled(app.receiptPairing.isBusy)
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView(fallbackMessage: "QR scanning is unavailable. Enter the pairing code instead.") { payload in
                    guard showScanner else { return }
                    showScanner = false
                    if let scanned = ReceiptPairingCode(qrPayload: payload) {
                        code = scanned.value
                        message = nil
                    } else {
                        message = "This isn’t a hestia pairing QR code."
                    }
                }
                .navigationTitle("Scan QR")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
            .appLanguage(app.appLanguage)
        }
    }

    private func submit() {
        guard let parsed = ReceiptPairingCode(code) else {
            message = "Enter the 8-character pairing code from hestia."
            return
        }
        message = nil
        Task {
            do {
                try await app.receiptPairing.pair(code: parsed, deviceName: ReceiptPairing.deviceName)
                if app.receiptPairing.status == .paired { dismiss() }
            } catch is CancellationError {
                dismiss()
            } catch let error as DevicePairingError {
                message = error.message
            } catch {
                message = DevicePairingError.redeemFailed.message
            }
        }
    }
}
