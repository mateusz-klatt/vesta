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
    func scene(_ op: Components.Schemas.SceneRequest.OpPayload) async throws
    func setThermostat(node: Int, celsius: Int) async throws
    func setThermostatPower(node: Int, on: Bool) async throws
    func sendIR(file: String, button: String) async throws
}
