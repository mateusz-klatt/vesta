import SwiftUI

struct PendingQRScan: Equatable {
    let payload: QRLoginPayload

    var displayedOrigin: String {
        // Isolate this left-to-right URL inside the translated prompt.
        "\u{2066}\(payload.origin.absoluteString)\u{2069}"
    }
}

@MainActor
@Observable
final class QRLoginPresentation {
    typealias SignIn = @MainActor (QRLoginPayload) async throws -> Void

    private(set) var pendingScan: PendingQRScan?
    private(set) var message: LocalizedStringResource?
    private(set) var isSigningIn = false

    func receiveScan(_ rawPayload: String, savedOverride: URL?, locale: Locale, signIn: SignIn) async {
        guard !isSigningIn, pendingScan == nil else { return }
        guard let payload = QRLoginPayload(rawValue: rawPayload) else {
            message = "This isn’t a hestia sign-in QR code."
            return
        }
        message = nil
        if let savedOverride, OriginMatcher.matches(savedOverride, payload.origin) {
            await submit(payload, locale: locale, signIn: signIn)
        } else {
            pendingScan = PendingQRScan(payload: payload)
        }
    }

    func confirm(_ scan: PendingQRScan, locale: Locale, signIn: SignIn) async {
        guard pendingScan == scan else { return }
        pendingScan = nil
        await submit(scan.payload, locale: locale, signIn: signIn)
    }

    func cancelConfirmation() { pendingScan = nil }

    private func submit(_ payload: QRLoginPayload, locale: Locale, signIn: SignIn) async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await signIn(payload)
        } catch is CancellationError {
            return
        } catch let error as QRLoginError {
            message = error.message(locale: locale)
        } catch let error as APIError {
            message = error.message
        } catch {
            message = "Couldn’t sign in"
        }
    }
}

/// Onboarding + sign-in + recovery. First run shows a calm "connect to your
/// server" setup (no error, no default host); a real failure shows friendly copy
/// with retry; a reachable-but-unauthenticated server shows sign-in.
struct ConnectView: View {
    @Environment(AppState.self) private var app
    @Environment(\.locale) private var locale

    @State private var urlText = ""
    @State private var user = ""
    @State private var password = ""
    @State private var urlInvalid = false
    @State private var showWhatIsThis = false
    @State private var showTechnical = false
    @State private var qrLogin = QRLoginPresentation()
    @State private var showScanner = false
    @State private var scannedPayload: String?
    @State private var showQRConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                switch app.phase {
                case .needsAuth:
                    signInSection
                    qrLoginSection
                    serverSection(title: "Server")
                case .failed(let error):
                    failureSection(error)
                    serverSection(title: "Server")
                default:
                    onboardingSection
                    qrLoginSection
                    serverSection(title: "Server address")
                }
            }
            .navigationTitle("Vesta")
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .sheet(isPresented: $showWhatIsThis) { whatIsThisSheet }
            .sheet(isPresented: $showScanner, onDismiss: completeQRScan) { scannerSheet }
            .alert("Sign in to this server?", isPresented: $showQRConfirmation, presenting: qrLogin.pendingScan) { scan in
                Button("Sign in") {
                    Task { await qrLogin.confirm(scan, locale: locale, signIn: app.signIn(with:)) }
                }
                Button("Cancel", role: .cancel) { qrLogin.cancelConfirmation() }
            } message: { scan in
                Text("Sign in to \(scan.displayedOrigin) using the scanned code?")
            }
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

    @ViewBuilder
    private var qrLoginSection: some View {
        if app.canScanQRLogin {
            Section {
                Button { showScanner = true } label: {
                    Label("Scan a code from Hestia", systemImage: "qrcode.viewfinder")
                }
                .disabled(qrLogin.isSigningIn)
                if qrLogin.isSigningIn { ProgressView() }
                if let message = qrLogin.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView { payload in
                guard showScanner else { return }
                scannedPayload = payload
                showScanner = false
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

    private func completeQRScan() {
        guard let scannedPayload else { return }
        self.scannedPayload = nil
        Task {
            await qrLogin.receiveScan(scannedPayload, savedOverride: app.savedBackendOverride,
                                      locale: locale, signIn: app.signIn(with:))
            showQRConfirmation = qrLogin.pendingScan != nil
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
                urlInvalid = !app.saveAndConnect(urlText) && app.sessionStorageError == nil
            }
            .disabled(urlText.isEmpty)
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Username", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button("Sign in") {
                Task { await app.login(user: user, password: password) }
            }
            .disabled(user.isEmpty || password.isEmpty)
        } header: {
            Text("Sign in")
        } footer: {
            if let notice = app.receiptPairing.revocationNotice {
                Text(notice)
            }
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
