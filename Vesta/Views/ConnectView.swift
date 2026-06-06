import SwiftUI

/// Onboarding + recovery surface: point Vesta at your hestia server and sign in.
/// Shown on first launch, when the session expires, or when a connection fails.
struct ConnectView: View {
    @Environment(AppState.self) private var app

    @State private var urlText = ""
    @State private var user = ""
    @State private var password = ""
    @State private var urlInvalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section("hestia server") {
                    TextField("https://hestia.example", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                    if urlInvalid {
                        Text("Enter just the origin, e.g. https://hestia.example (no path). Plain http is allowed for a LAN address.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button("Save & connect") {
                        urlInvalid = !app.setBackend(urlText)
                    }
                }

                Section("Sign in") {
                    TextField("Username", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button("Sign in") {
                        Task { await app.login(user: user, password: password) }
                    }
                    .disabled(user.isEmpty || password.isEmpty)
                }

                if case .failed(let message) = app.phase {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Vesta")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .onAppear { if urlText.isEmpty { urlText = app.backendURLString } }
        }
    }
}
