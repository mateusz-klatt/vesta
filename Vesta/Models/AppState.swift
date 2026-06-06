import Foundation
import Observation

/// Single source of truth for the app session: which backend, are we
/// authenticated, and the latest device snapshot. Owns the API client and the
/// live event subscription.
@MainActor
@Observable
final class AppState {

    enum Phase: Equatable {
        case connecting
        case needsAuth
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    private(set) var whoami: Components.Schemas.WhoAmI?
    private(set) var rooms: [RoomGroup] = []
    private(set) var summary: Summary?
    private(set) var globals: Globals?
    var backendURLString: String = AppConfig.serverURL.absoluteString

    private let api = APIClient()
    private var eventTask: Task<Void, Never>?

    /// Entry point: probe the session, then load state or fall back to auth.
    func bootstrap() async {
        phase = .connecting
        do {
            whoami = try await api.whoami()
            await loadDiscovery()
            startEvents()
        } catch APIError.unauthorized {
            phase = .needsAuth
        } catch {
            phase = .failed(message(error))
        }
    }

    func login(user: String, password: String) async {
        do {
            _ = try await api.login(user: user, password: password)
            whoami = try await api.whoami()
            await loadDiscovery()
            startEvents()
        } catch {
            phase = .failed(message(error))
        }
    }

    /// Validate + persist a new backend origin, then reconnect. Returns false
    /// (without side effects) if the input is not a valid origin.
    @discardableResult
    func setBackend(_ raw: String) -> Bool {
        guard let url = BackendURLStore.canonicalize(raw) else { return false }
        BackendURLStore.shared.saveOverride(url)
        backendURLString = url.absoluteString
        eventTask?.cancel()
        Task {
            await api.logout()
            await bootstrap()
        }
        return true
    }

    func loadDiscovery() async {
        do {
            let discovery = try await api.discovery()
            rooms = RoomGroup.group(discovery)
            summary = discovery.summary
            globals = discovery.globals
            phase = .ready
        } catch APIError.unauthorized {
            phase = .needsAuth
        } catch {
            phase = .failed(message(error))
        }
    }

    func toggle(_ item: IdentifiedDevice, on: Bool, endpoint: Int? = nil) async {
        guard let node = Int(item.id) else { return }
        do {
            try await api.setSwitch(node: node, on: on, endpoint: endpoint)
            await loadDiscovery()
        } catch {
            phase = .failed(message(error))
        }
    }

    private func startEvents() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await _ in EventStream.ticks() {
                await self?.loadDiscovery()
            }
        }
    }

    private func message(_ error: any Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}
