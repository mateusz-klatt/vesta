import SwiftUI
import VisionKit

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
                    if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
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
                PairingQRScanner { result in
                    showScanner = false
                    switch result {
                    case .payload(let payload):
                        if let scanned = ReceiptPairingCode(qrPayload: payload) {
                            code = scanned.value
                            message = nil
                        } else {
                            message = "This isn’t a hestia pairing QR code."
                        }
                    case .unavailable:
                        message = "QR scanning is unavailable. Enter the pairing code instead."
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

private struct PairingQRScanner: UIViewControllerRepresentable {
    enum ScanResult { case payload(String), unavailable }

    let onResult: (ScanResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            recognizesMultipleItems: false
        )
        scanner.delegate = context.coordinator
        context.coordinator.start(scanner)
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.startTask?.cancel()
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (ScanResult) -> Void
        var startTask: Task<Void, Never>?
        private var finished = false

        init(onResult: @escaping (ScanResult) -> Void) { self.onResult = onResult }

        func start(_ scanner: DataScannerViewController) {
            startTask = Task { [weak self, weak scanner] in
                guard !Task.isCancelled, let scanner else { return }
                do {
                    try scanner.startScanning()
                } catch {
                    self?.finish(.unavailable, scanner: scanner)
                }
            }
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard case .barcode(let barcode)? = addedItems.first else { return }
            finish(.payload(barcode.payloadStringValue ?? ""), scanner: scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(.unavailable, scanner: scanner)
        }

        private func finish(_ result: ScanResult, scanner: DataScannerViewController) {
            guard !finished else { return }
            finished = true
            scanner.stopScanning()
            onResult(result)
        }
    }
}
