import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// A connection/usage error mapped to human, App-Store-friendly copy. The raw
/// description is kept only in ``technical`` (shown behind a disclosure / logs),
/// never surfaced as the primary message.
enum APIError: LocalizedError, Equatable {
    case unauthorized
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
/// stores the token in the Keychain, and ``BearerAuthMiddleware`` attaches it to
/// every subsequent request. Rebuilt when the user points Vesta at a new backend.
actor APIClient: HestiaAPI {
    private var serverURL: URL
    private var client: Client
    private let transport: any ClientTransport

    init(transport: any ClientTransport = URLSessionTransport()) {
        self.transport = transport
        serverURL = AppConfig.serverURL
        client = APIClient.make(serverURL, transport)
    }

    private static func make(_ url: URL, _ transport: any ClientTransport) -> Client {
        Client(
            serverURL: url,
            transport: transport,
            middlewares: [BearerAuthMiddleware(token: { TokenStore.load() })]
        )
    }

    private func refresh() {
        let current = AppConfig.serverURL
        if current != serverURL {
            serverURL = current
            client = APIClient.make(current, transport)
        }
    }

    func whoami() async throws -> Components.Schemas.WhoAmI {
        refresh()
        do {
            switch try await client.whoami(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw APIError.wrap(error) }
    }

    func discovery() async throws -> Components.Schemas.Discovery {
        refresh()
        do {
            switch try await client.discovery(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw APIError.wrap(error) }
    }

    @discardableResult
    func login(user: String, password: String) async throws -> Components.Schemas.LoginSuccess {
        refresh()
        do {
            switch try await client.login(.init(body: .json(.init(bearer: true, password: password, user: user)))) {
            case .ok(let ok):
                let success = try ok.body.json
                if let token = success.token { TokenStore.save(token) }
                return success
            case .unauthorized: throw APIError.unauthorized
            case .undocumented(let code, _): throw mapStatus(code)
            }
        } catch { throw APIError.wrap(error) }
    }

    func logout() async {
        refresh()
        _ = try? await client.logout(.init())
        TokenStore.clear()
    }

    func setSwitch(node: Int, on: Bool, endpoint: Int? = nil) async throws {
        try await sendControl(._switch(.init(endpoint: endpoint, node: node, on: on, op: ._switch)))
    }

    func setCover(node: Int, value: Int) async throws {
        try await sendControl(.cover(.init(node: node, op: .cover, value: max(0, min(99, value)))))
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
        } catch { throw APIError.wrap(error) }
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
        } catch { throw APIError.wrap(error) }
    }

    private func mapStatus(_ code: Int) -> APIError {
        (code == 401 || code == 403) ? .unauthorized : .http(code)
    }
}
