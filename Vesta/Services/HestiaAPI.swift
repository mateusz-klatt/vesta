import Foundation

/// The hestia operations the app needs. Abstracted so `AppState` can be unit-
/// tested against a mock (the real implementation is ``APIClient``).
protocol HestiaAPI: Sendable {
    func whoami() async throws -> Components.Schemas.WhoAmI
    func discovery() async throws -> Components.Schemas.Discovery
    @discardableResult
    func login(user: String, password: String) async throws -> Components.Schemas.LoginSuccess
    func logout() async
    func setSwitch(node: Int, on: Bool, endpoint: Int?) async throws
    func setCover(node: Int, value: Int) async throws
    /// Run a house-wide scene. `value` is the wire position (0–99) for `blindsSet`
    /// (whole-home blind slider); the valueless sweeps (lights/blinds up-down) pass nil.
    func scene(_ op: Components.Schemas.SceneRequest.OpPayload, value: Int?) async throws
    func setThermostat(node: Int, celsius: Int) async throws
    func setThermostatPower(node: Int, on: Bool) async throws
    func sendIR(file: String, button: String) async throws
}

extension HestiaAPI {
    /// Convenience for the valueless sweeps (lights on/off, blinds up/down).
    func scene(_ op: Components.Schemas.SceneRequest.OpPayload) async throws {
        try await scene(op, value: nil)
    }
}
