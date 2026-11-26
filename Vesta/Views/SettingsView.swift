import SwiftUI

/// Minimal settings: change the server, pick units + language, sign out.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var urlInvalid = false
    @State private var pairingPresentation = ReceiptPairingPresentation()
    @State private var pairingMessage: LocalizedStringResource?

    /// Languages Vesta ships (matches the String Catalog).
    static let languages = [
        "ar", "bn", "bs", "cs", "da", "de", "el", "en", "es", "fa", "fi", "fil",
        "fr", "ga", "he", "hi", "hr", "hu", "hy", "id", "is", "it", "ja", "ko",
        "lt", "lv", "ms", "my", "nb", "nl", "pl", "pt-BR", "ro", "ru", "sk", "sq",
        "sr-Latn", "sv", "sw", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
    ]

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address") {
                        Text(verbatim: app.backendURLString).foregroundStyle(Theme.textSecondary)
                    }
                    TextField("https://hestia.example", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    if urlInvalid {
                        Text("Enter just the origin, e.g. https://hestia.example (no path).")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    if let error = app.sessionStorageError {
                        Text(error.message).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Save & connect") {
                        if app.saveAndConnect(urlText) { dismiss() } else { urlInvalid = app.sessionStorageError == nil }
                    }
                    .disabled(urlText.isEmpty)
                }

                Section("Display") {
                    Picker("Temperature", selection: $app.tempScale) {
                        Text("Celsius (°C)").tag(TempScale.celsius)
                        Text("Fahrenheit (°F)").tag(TempScale.fahrenheit)
                    }
                    Picker("Language", selection: $app.appLanguage) {
                        // Single Text (not an HStack) so the menu picker's collapsed
                        // value renders it; interpolating Text keeps "System" localized.
                        Text("🌐  \(Text("System"))").tag(String?.none)
                        ForEach(Self.languages, id: \.self) { code in
                            Text(verbatim: "\(Lang.flag(code))  \(Lang.autonym(code))").tag(String?.some(code))
                        }
                    }
                }

                if app.receiptsAPI != nil {
                    Section("Receipts") {
                        if app.receiptPairing.status == .paired {
                            Text("Paired")
                            if app.receiptsUseExchange && !app.receiptPairing.requiresExchangeSignIn {
                                Button("Pair again") { pairingPresentation.present(in: app) }
                            }
                            Button("Unpair iPhone", role: .destructive) {
                                pairingMessage = nil
                                Task {
                                    do {
                                        try await app.receiptPairing.unpair()
                                    } catch {
                                        pairingMessage = DevicePairingError.storage.message
                                    }
                                }
                            }
                        } else if !app.receiptPairing.requiresExchangeSignIn {
                            Text("Not paired")
                            Button {
                                pairingPresentation.present(in: app)
                            } label: {
                                if app.receiptPairing.status == .pairAgain { Text("Pair again") }
                                else { Text("Pair iPhone") }
                            }
                        }
                        if let notice = pairingMessage ?? app.receiptPairing.pairingNotice {
                            Text(notice).foregroundStyle(Theme.textSecondary)
                        }
                        if let notice = app.receiptPairing.revocationNotice {
                            Text(notice).foregroundStyle(Theme.textSecondary)
                        }
                        if app.receiptsUseExchange && app.receiptPairing.requiresExchangeSignIn {
                            Button("Sign in") { if app.signInAgainForDeviceExchange() { dismiss() } }
                        }
                        ReceiptDeviceLimitDetails(limit: app.receiptPairing.deviceLimit)
                    }
                    .disabled(app.receiptPairing.isBusy)
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { if await app.signOut() { dismiss() } }
                    }
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear {
                urlText = app.backendURLString
                app.receiptPairing.refreshStatus()
            }
            .receiptPairingSheet($pairingPresentation, app: app)
            .receiptNewDeviceAlert(app: app, enabled: !pairingPresentation.isPresented(accessGeneration: app.receiptAccessGeneration))
        }
    }
}
