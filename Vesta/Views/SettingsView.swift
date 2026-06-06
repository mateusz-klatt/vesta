import SwiftUI

/// Minimal settings: change the server, pick units + language, sign out.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var urlInvalid = false

    /// Languages Vesta ships (matches the String Catalog).
    private static let languages = [
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
                    Button("Save & connect") {
                        if app.saveAndConnect(urlText) { dismiss() } else { urlInvalid = true }
                    }
                    .disabled(urlText.isEmpty)
                }

                Section("Display") {
                    Picker("Temperature", selection: $app.tempScale) {
                        Text("Celsius (°C)").tag(TempScale.celsius)
                        Text("Fahrenheit (°F)").tag(TempScale.fahrenheit)
                    }
                    Picker("Language", selection: $app.appLanguage) {
                        Text("System").tag(String?.none)
                        ForEach(Self.languages, id: \.self) { code in
                            Text(Self.displayName(code)).tag(String?.some(code))
                        }
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await app.signOut(); dismiss() }
                    }
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { urlText = app.backendURLString }
        }
    }

    private static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized ?? code
    }
}
