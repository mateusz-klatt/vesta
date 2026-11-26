import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A connection/usage error mapped to human, App-Store-friendly copy. The raw
/// description is kept only in ``technical`` (shown behind a disclosure / logs),
/// never surfaced as the primary message.
enum APIError: LocalizedError, Equatable {
    case unauthorized
    case forbidden
    case serverNotFound
    case timedOut
    case offline
    case tls
    case cannotConnect
    case credentialStorage
    case http(Int)
    case unexpected(String)

    var title: LocalizedStringResource {
        switch self {
        case .unauthorized: "Sign-in required"
        case .forbidden: "Not allowed"
        case .serverNotFound: "Server not found"
        case .timedOut: "Server didn’t respond"
        case .offline: "No internet connection"
        case .tls: "Secure connection problem"
        case .cannotConnect: "Couldn’t reach server"
        case .http: "Server error"
        case .credentialStorage, .unexpected: "Couldn’t connect"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case .unauthorized: "Enter your username and password."
        case .forbidden: "You don’t have permission to use this feature."
        case .serverNotFound: "Check the server address and try again."
        case .timedOut: "The server took too long to answer. Check Wi-Fi, VPN, or the server."
        case .offline: "Your iPhone appears to be offline."
        case .tls: "The server’s certificate could not be verified."
        case .cannotConnect: "Check the address and that the server is running."
        case .credentialStorage: DevicePairingError.storage.message
        case .http(let code): "The server returned an error (\(code))."
        case .unexpected: "Check the address and try again."
        }
    }

    var technical: String? {
        if case .unexpected(let detail) = self { return detail }
        return nil
    }

    var errorDescription: String? { String(localized: message) }

    static func isCancellation(_ error: any Error) -> Bool {
        if let clientError = error as? ClientError { return isCancellation(clientError.underlyingError) }
        return error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    static func wrap(_ error: any Error) -> APIError {
        if let api = error as? APIError { return api }
        // The generated client wraps transport failures in ClientError.
        if let clientError = error as? ClientError { return wrap(clientError.underlyingError) }
        if (error as? SessionKeychainError) == .locked { return .credentialStorage }
        if case .storage = error as? DevicePairingError { return .credentialStorage }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed: return .serverNotFound
            case .timedOut: return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .offline
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot: return .tls
            case .cannotConnectToHost, .cannotLoadFromNetwork: return .cannotConnect
            default: return .unexpected(urlError.localizedDescription)
            }
        }
        return .unexpected(error.localizedDescription)
    }
}

/// Typed hestia client built on the generated `Client` (from `Vesta/openapi.json`).
/// Each generated client holds the origin and credentials captured for one request.
actor APIClient: HestiaAPI {
    private let backendURLStore: BackendURLStore
    private let sessionStore: CredentialSessionStore?
    private let receiptPairing: ReceiptPairing?
    private let transport: any ClientTransport
    private let probeTransport: any ClientTransport
    private let budgetScopeOverride: ReceiptSessionScope?
    let budgetEnabled: @Sendable () -> Bool

    // The streaming transport installs its own task delegate. Use the session's
    // redirect delegate for generated REST requests.
    init(transport: (any ClientTransport)? = nil,
         receiptPairing: ReceiptPairing? = nil,
         sessionStore: CredentialSessionStore? = nil,
         budgetEnabled: @escaping @Sendable () -> Bool = { AppConfig.nativeBudgetEnabledForBuild },
         budgetScopeOverride: ReceiptSessionScope? = nil) {
        self.transport = transport ?? URLSessionTransport(
            configuration: .init(session: HTTPSession.shared, httpBodyProcessingMode: .buffered))
        probeTransport = transport ?? URLSessionTransport(
            configuration: .init(session: HTTPSession.featuresProbe, httpBodyProcessingMode: .buffered))
        backendURLStore = sessionStore?.backendURLStore ?? .shared
        self.sessionStore = sessionStore
        self.receiptPairing = receiptPairing
        self.budgetEnabled = budgetEnabled
        self.budgetScopeOverride = budgetScopeOverride
    }

    private func makeClient(on origin: URL, session: BoundSession?) -> Client {
        Client(
            serverURL: origin,
            transport: transport,
            middlewares: [
                BearerAuthMiddleware(session: session, receiptPairing: receiptPairing, budgetEnabled: budgetEnabled),
                ExplicitNullsMiddleware(),
            ]
        )
    }

    func requestClient(on origin: URL? = nil) -> Client {
        let session = sessionStore?.currentSnapshot()
        return makeClient(on: origin ?? session?.origin ?? backendURLStore.currentEffectiveURL(), session: session)
    }

    func currentBudgetScope() async -> ReceiptSessionScope? {
        guard let session = sessionStore?.currentSnapshot(),
              let device = await receiptPairing?.nativeBudgetCredential(for: session.origin, session: session) else { return nil }
        let current = ReceiptSessionScope(
            origin: session.origin, actor: session.actor, ownerKey: device.ownerKey, credential: device.credential
        )
        if let budgetScopeOverride { return budgetScopeOverride == current ? current : nil }
        return current
    }

    func bindBudgetScope(_ scope: ReceiptSessionScope) -> any BudgetAPI {
        APIClient(
            transport: transport, receiptPairing: receiptPairing, sessionStore: sessionStore,
            budgetEnabled: budgetEnabled, budgetScopeOverride: scope
        )
    }

    func isCurrentBudgetScope(_ scope: ReceiptSessionScope) async -> Bool {
        await currentBudgetScope() == scope
    }

    func requestReceiptClient(scope: ReceiptSessionScope?) -> Client {
        guard let scope else { return requestClient() }
        return Client(
            serverURL: scope.origin,
            transport: transport,
            middlewares: [
                ExplicitNullsMiddleware(),
                BearerAuthMiddleware(session: sessionStore?.currentSnapshot(), receiptPairing: receiptPairing,
                                     receiptScope: scope, budgetEnabled: budgetEnabled),
            ]
        )
    }

    func whoami() async throws -> Components.Schemas.WhoAmI {
        try await whoami(using: requestClient())
    }

    private func whoami(using client: Client) async throws -> Components.Schemas.WhoAmI {
        do {
            switch try await client.whoami(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func probeFeatures(on origin: URL) async throws -> ServerFeatures {
        try Task.checkCancellation()
        guard origin.user == nil, origin.password == nil else { throw URLError(.badURL) }
        let probe = Client(serverURL: origin, transport: probeTransport)
        do {
            guard case .ok(let ok) = try await probe.authFeatures(.init()) else { return .legacy }
            return try ok.body.json.serverFeatures
        } catch {
            let underlying = (error as? ClientError)?.underlyingError ?? error
            if let urlError = underlying as? URLError { throw urlError }
            if underlying is CancellationError { throw CancellationError() }
            return .legacy
        }
    }

    func capabilities(on origin: URL, features: ServerFeatures) async throws -> Capabilities {
        try await capabilities(using: requestClient(on: origin), features: features)
    }

    func verifyLegacySession(_ session: BoundSession, features: ServerFeatures) async throws -> Capabilities {
        try await capabilities(using: makeClient(on: session.origin, session: session), features: features)
    }

    private func capabilities(using client: Client, features: ServerFeatures) async throws -> Capabilities {
        try Task.checkCancellation()
        guard features.supports(.capabilities) else {
            let identity = try await whoami(using: client)
            return Capabilities.fromLegacyRole(role: identity.role, user: identity.user)
        }
        do {
            switch try await client.meCapabilities(.init()) {
            case .ok(let ok): return try ok.body.json.capabilities
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func discovery() async throws -> Components.Schemas.Discovery {
        let client = requestClient()
        do {
            switch try await client.discovery(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    @discardableResult
    func login(user: String, password: String, on origin: URL) async throws -> Components.Schemas.LoginSuccess {
        let client = makeClient(on: origin, session: nil)
        do {
            switch try await client.login(.init(body: .json(.init(bearer: true, password: password, user: user)))) {
            case .ok(let ok): return try ok.body.json
            case .unauthorized: throw APIError.unauthorized
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func remoteLogout(token: String, origin: URL) async {
        let session = BoundSession(origin: origin, actor: nil, token: token)
        _ = try? await makeClient(on: origin, session: session).logout(.init())
    }

    func setSwitch(node: Int, on: Bool, endpoint: Int? = nil) async throws {
        try await sendControl(._switch(.init(endpoint: endpoint, node: node, on: on, op: ._switch)))
    }

    func setCover(node: Int, value: Int) async throws {
        try await sendControl(.cover(.init(node: node, op: .cover, value: max(0, min(99, value)))))
    }

    /// Run a house-wide scene (all lights/blinds). The server expands the sweep
    /// and honors the registry's whole-home exclusions, which aren't exposed to
    /// clients — so this must stay a single server-side call. `value` is the wire
    /// position (0–99) for `blindsSet`; nil for the valueless sweeps.
    func scene(_ op: Components.Schemas.SceneRequest.OpPayload, value: Int?) async throws {
        let client = requestClient()
        do {
            let wire = value.map { max(0, min(99, $0)) }
            switch try await client.scene(.init(body: .json(.init(op: op, value: wire)))) {
            case .ok: return
            case .badRequest: throw APIError.http(400)
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func setThermostat(node: Int, celsius: Int) async throws {
        try await sendControl(.thermostat(.init(celsius: .init(value1: max(4, min(28, celsius))), node: node, op: .thermostat)))
    }

    func setThermostatPower(node: Int, on: Bool) async throws {
        try await sendControl(.thermostatPower(.init(node: node, on: on, op: .thermostatPower)))
    }

    /// Transmit a saved Flipper IR signal — used for the A/C (klima) panel.
    func sendIR(file: String, button: String) async throws {
        let client = requestClient()
        do {
            switch try await client.ir(.init(body: .json(.init(button: button, file: file)))) {
            case .ok: return
            case .badRequest: throw APIError.http(400)
            case .serviceUnavailable: throw APIError.http(503)
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    private func sendControl(_ body: Components.Schemas.ControlRequest) async throws {
        let client = requestClient()
        do {
            switch try await client.control(.init(body: .json(body))) {
            case .ok: return
            case .badRequest: throw APIError.http(400)
            case .serviceUnavailable: throw APIError.http(503)
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func mapStatus(_ code: Int) -> APIError {
        switch code {
        case 401: .unauthorized
        case 403: .forbidden
        default: .http(code)
        }
    }

    private static func requestError(_ error: any Error) -> any Error {
        if APIError.isCancellation(error) { return CancellationError() }
        return APIError.wrap(error)
    }
}
