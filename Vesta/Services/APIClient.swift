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
        case .unexpected: "Couldn’t connect"
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
/// Auth is a bearer token: ``login(user:password:)`` requests `bearer: true`,
/// stores the token in the Keychain, and ``BearerAuthMiddleware`` uses it for
/// session operations. Receipt operations use a separate device credential.
actor APIClient: HestiaAPI {
    private var serverURL: URL
    private(set) var client: Client
    private let transport: any ClientTransport
    private let auth: BearerAuthMiddleware
    private let saveToken: @Sendable (String) -> Void
    private let clearToken: @Sendable () -> Void
    /// Bumped by ``logout()``. A login whose response lands after a logout
    /// started must not store its token, or a signed-out app wakes up signed in.
    private var authEpoch = 0
    /// Bumped on every saved token, so a logout still waiting on the server
    /// doesn't wipe the token of a login that finished in the meantime.
    private var tokenVersion = 0

    // The streaming transport installs its own task delegate. Use the session's
    // redirect delegate for generated REST requests.
    init(transport: any ClientTransport = URLSessionTransport(
            configuration: .init(session: HTTPSession.shared, httpBodyProcessingMode: .buffered)),
         receiptPairing: ReceiptPairing? = nil,
         sessionToken: @escaping @Sendable () -> String? = { TokenStore.load() },
         saveToken: @escaping @Sendable (String) -> Void = { TokenStore.save($0) },
         clearToken: @escaping @Sendable () -> Void = { TokenStore.clear() }) {
        self.transport = transport
        self.saveToken = saveToken
        self.clearToken = clearToken
        auth = BearerAuthMiddleware(token: sessionToken, receiptPairing: receiptPairing)
        serverURL = AppConfig.serverURL
        client = APIClient.make(serverURL, transport, auth)
    }

    private static func make(_ url: URL, _ transport: any ClientTransport, _ auth: BearerAuthMiddleware) -> Client {
        Client(
            serverURL: url,
            transport: transport,
            middlewares: [auth, ExplicitNullsMiddleware()]
        )
    }

    func refresh() {
        let current = AppConfig.serverURL
        if current != serverURL {
            serverURL = current
            client = APIClient.make(current, transport, auth)
        }
    }

    func whoami() async throws -> Components.Schemas.WhoAmI {
        refresh()
        do {
            switch try await client.whoami(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    func capabilities() async throws -> Capabilities {
        let identity = try await whoami()
        return Capabilities.fromLegacyRole(role: identity.role, user: identity.user)
    }

    func discovery() async throws -> Components.Schemas.Discovery {
        refresh()
        do {
            switch try await client.discovery(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
    }

    @discardableResult
    func login(user: String, password: String) async throws -> Components.Schemas.LoginSuccess {
        refresh()
        let epoch = authEpoch
        let success: Components.Schemas.LoginSuccess
        do {
            switch try await client.login(.init(body: .json(.init(bearer: true, password: password, user: user)))) {
            case .ok(let ok): success = try ok.body.json
            case .unauthorized: throw APIError.unauthorized
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw Self.requestError(error) }
        // Actor-isolated, so this check and the save can't interleave with logout().
        guard epoch == authEpoch else { throw CancellationError() }
        if let token = success.token {
            saveToken(token)
            tokenVersion += 1
        }
        return success
    }

    func logout() async {
        authEpoch += 1
        let version = tokenVersion
        refresh()
        _ = try? await client.logout(.init())
        // A login that began after this logout and already saved its token wins.
        guard version == tokenVersion else { return }
        clearToken()
    }

    func invalidateSession() {
        authEpoch += 1
        clearToken()
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
        refresh()
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
        refresh()
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
        refresh()
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
