import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

enum APIError: LocalizedError {
    case unauthorized
    case http(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return String(localized: "Sign-in required.")
        case .http(let code): return String(localized: "Server error (HTTP \(code)).")
        case .transport(let message): return String(localized: "Can't connect: \(message)")
        }
    }
}

/// Typed hestia client built on the generated `Client` (from `Vesta/openapi.json`).
/// Auth is a bearer token (native-client flow): ``login(user:password:)`` requests
/// `bearer: true`, stores the returned token in the Keychain, and
/// ``BearerAuthMiddleware`` attaches it to every subsequent request. The client is
/// rebuilt when the user points Vesta at a different backend.
actor APIClient {
    private var serverURL: URL
    private var client: Client

    init() {
        serverURL = AppConfig.serverURL
        client = APIClient.make(serverURL)
    }

    private static func make(_ url: URL) -> Client {
        Client(
            serverURL: url,
            transport: URLSessionTransport(),
            middlewares: [BearerAuthMiddleware(token: { TokenStore.load() })]
        )
    }

    private func refresh() {
        let current = AppConfig.serverURL
        if current != serverURL {
            serverURL = current
            client = APIClient.make(current)
        }
    }

    func whoami() async throws -> Components.Schemas.WhoAmI {
        refresh()
        do {
            switch try await client.whoami(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw map(code)
            }
        } catch let error as APIError { throw error } catch { throw APIError.transport(error.localizedDescription) }
    }

    func discovery() async throws -> Components.Schemas.Discovery {
        refresh()
        do {
            switch try await client.discovery(.init()) {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let code, _): throw map(code)
            }
        } catch let error as APIError { throw error } catch { throw APIError.transport(error.localizedDescription) }
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
            case .undocumented(let code, _): throw map(code)
            }
        } catch let error as APIError { throw error } catch { throw APIError.transport(error.localizedDescription) }
    }

    func logout() async {
        refresh()
        _ = try? await client.logout(.init())
        TokenStore.clear()
    }

    func setSwitch(node: Int, on: Bool, endpoint: Int? = nil) async throws {
        refresh()
        let command = Components.Schemas.ControlRequest._switch(.init(endpoint: endpoint, node: node, on: on, op: ._switch))
        do {
            switch try await client.control(.init(body: .json(command))) {
            case .ok: return
            case .badRequest: throw APIError.http(400)
            case .serviceUnavailable: throw APIError.http(503)
            case .undocumented(let code, _): throw map(code)
            }
        } catch let error as APIError { throw error } catch { throw APIError.transport(error.localizedDescription) }
    }

    private func map(_ code: Int) -> APIError {
        (code == 401 || code == 403) ? .unauthorized : .http(code)
    }
}
