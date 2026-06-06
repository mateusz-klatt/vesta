import SwiftUI

/// Onboarding + sign-in + recovery. First run shows a calm "connect to your
/// server" setup (no error, no default host); a real failure shows friendly copy
/// with retry; a reachable-but-unauthenticated server shows sign-in.
struct ConnectView: View {
    @Environment(AppState.self) private var app

    @State private var urlText = ""
    @State private var user = ""
    @State private var password = ""
    @State private var urlInvalid = false
    @State private var showWhatIsThis = false
    @State private var showTechnical = false

    var body: some View {
        NavigationStack {
            Form {
                switch app.phase {
                case .needsAuth:
                    signInSection
                    serverSection(title: "Server")
                case .failed(let error):
                    failureSection(error)
                    serverSection(title: "Server")
                default:
                    onboardingSection
                    serverSection(title: "Server address")
                }
            }
            .navigationTitle("Vesta")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(isPresented: $showWhatIsThis) { whatIsThisSheet }
            .onAppear {
                if urlText.isEmpty, app.phase != .unconfigured { urlText = app.backendURLString }
            }
        }
    }

    private var onboardingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Connect to your hestia server", systemImage: "house")
                    .font(.headline)
                Text("Enter the address of the hestia server set up for your home.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("What is this?") { showWhatIsThis = true }
                    .font(.footnote)
            }
            .padding(.vertical, 4)
        }
    }

    private func serverSection(title: LocalizedStringKey) -> some View {
        Section(title) {
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
                urlInvalid = !app.saveAndConnect(urlText)
            }
            .disabled(urlText.isEmpty)
        }
    }

    private var signInSection: some View {
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
    }

    private func failureSection(_ error: APIError) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(error.title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button("Try again") { Task { await app.connect() } }
                if let technical = error.technical {
                    Button(showTechnical ? "Hide details" : "Technical details") {
                        showTechnical.toggle()
                    }
                    .font(.footnote)
                    if showTechnical {
                        Text(verbatim: technical).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var whatIsThisSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("What is hestia?", systemImage: "house")
                    .font(.title2.bold())
                Text("Vesta controls a private hestia server set up for your home — it isn’t a cloud service. Ask the person who set it up for the address (for example https://hestia.example or a http:// address on your home network).")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding()
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showWhatIsThis = false }
                }
            }
        }
    }
}
