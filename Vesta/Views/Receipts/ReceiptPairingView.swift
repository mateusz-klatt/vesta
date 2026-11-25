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

    func receiptNewDeviceAlert(app: AppState, enabled: Bool) -> some View {
        alert("This iPhone was paired as a new device.", isPresented: Binding(
            get: { enabled && app.receiptPairing.showNewDeviceAlert },
            set: { if !$0 { app.receiptPairing.dismissNewDeviceAlert() } }
        )) {
            Button("OK", role: .cancel) {}
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
                if !app.receiptsUseExchange {
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
                }
                if let message = message ?? app.receiptPairing.pairingNotice {
                    Text(message).foregroundStyle(Theme.textSecondary)
                }
                ReceiptDeviceLimitDetails(limit: app.receiptPairing.deviceLimit)
                Section {
                    if app.receiptsUseExchange && app.receiptPairing.requiresExchangeSignIn {
                        Button("Sign in") { if app.signInAgainForDeviceExchange() { dismiss() } }
                    } else {
                        Button { submit() } label: {
                            if app.receiptPairing.status == .notPaired { Text("Pair iPhone") }
                            else { Text("Pair again") }
                        }
                        .disabled(!app.receiptsUseExchange && code.isEmpty)
                    }
                }
            }
            .disabled(app.receiptPairing.isBusy)
            .overlay {
                if app.receiptPairing.isBusy { ProgressView() }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(app.receiptPairing.status == .notPaired ? Text("Pair iPhone") : Text("Pair again"))
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
        let useExchange = app.receiptsUseExchange
        let parsed = ReceiptPairingCode(code)
        guard useExchange || parsed != nil else {
            message = "Enter the 8-character pairing code from hestia."
            return
        }
        message = nil
        Task {
            do {
                if useExchange {
                    try await app.pairReceiptsByExchange()
                } else if let parsed {
                    try await app.receiptPairing.pair(code: parsed, deviceName: ReceiptPairing.deviceName)
                }
                if app.receiptPairing.status == .paired { dismiss() }
            } catch is CancellationError {
                dismiss()
            } catch let error as DevicePairingError {
                message = app.receiptPairing.pairingNotice ?? error.message
            } catch {
                message = useExchange
                    ? app.receiptPairing.pairingNotice ?? APIError.cannotConnect.message
                    : DevicePairingError.redeemFailed.message
            }
        }
    }
}

struct ReceiptDeviceLimitDetails: View {
    let limit: DeviceExchangeLimit?

    var body: some View {
        if let limit {
            VStack(alignment: .leading) {
                Text(verbatim: limit.deviceName)
                if let tokenID = limit.tokenID {
                    Text(verbatim: tokenID).font(.caption.monospaced())
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .privacySensitive()
        }
    }
}
