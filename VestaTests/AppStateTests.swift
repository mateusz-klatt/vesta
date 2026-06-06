import XCTest
@testable import Vesta

/// Records every call; `discovery()` throws so the follow-up reload doesn't need
/// a fully-built Discovery — we assert the control calls (and their order).
actor MockHestiaAPI: HestiaAPI {
    enum Call: Equatable {
        case whoami, discovery, logout
        case login(String, String)
        case setSwitch(Int, Bool, Int?)
        case setCover(Int, Int)
        case setThermostat(Int, Int)
        case setThermostatPower(Int, Bool)
        case sendIR(String, String)
    }

    private(set) var calls: [Call] = []
    private var whoamiResult = Components.Schemas.WhoAmI(role: "operator", user: "u")

    func setWhoami(role: String?) { whoamiResult = .init(role: role, user: "u") }

    func whoami() async throws -> Components.Schemas.WhoAmI { calls.append(.whoami); return whoamiResult }
    func discovery() async throws -> Components.Schemas.Discovery { calls.append(.discovery); throw APIError.http(599) }
    @discardableResult
    func login(user: String, password: String) async throws -> Components.Schemas.LoginSuccess {
        calls.append(.login(user, password)); return .init(ok: true, token: "t", user: user)
    }
    func logout() async { calls.append(.logout) }
    func setSwitch(node: Int, on: Bool, endpoint: Int?) async throws { calls.append(.setSwitch(node, on, endpoint)) }
    func setCover(node: Int, value: Int) async throws { calls.append(.setCover(node, value)) }
    func setThermostat(node: Int, celsius: Int) async throws { calls.append(.setThermostat(node, celsius)) }
    func setThermostatPower(node: Int, on: Bool) async throws { calls.append(.setThermostatPower(node, on)) }
    func sendIR(file: String, button: String) async throws { calls.append(.sendIR(file, button)) }
}

@MainActor
final class AppStateTests: XCTestCase {

    private func device(_ id: String, type: String, on: Bool? = nil, setpoint: Double? = nil) -> IdentifiedDevice {
        IdentifiedDevice(id: id, device: .init(setpoint: setpoint, _switch: on, _type: type))
    }

    func testToggleSendsSwitch() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.toggle(device("4", type: "light"), on: true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(4, true, nil)))
    }

    func testSetCoverMapsPercentToValue() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setCover(device("5", type: "blind"), percent: 100)
        await app.setCover(device("5", type: "blind"), percent: 0)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setCover(5, 99)))
        XCTAssertTrue(calls.contains(.setCover(5, 0)))
    }

    func testSetThermostatPowersOnThenSets() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostat(device("9", type: "thermostat"), celsius: 22)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(2)), [.setThermostatPower(9, true), .setThermostat(9, 22)])
    }

    func testThermostatOffGoesTo4ThenOff() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostatPower(device("9", type: "thermostat"), on: false)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(2)), [.setThermostat(9, 4), .setThermostatPower(9, false)])
    }

    func testThermostatOnJustPowersOn() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.setThermostatPower(device("9", type: "thermostat"), on: true)
        let calls = await mock.calls
        XCTAssertEqual(Array(calls.prefix(1)), [.setThermostatPower(9, true)])
    }

    func testLoginSetsIdentity() async {
        let mock = MockHestiaAPI()
        await mock.setWhoami(role: "operator")
        let app = AppState(api: mock)
        await app.login(user: "alice", password: "pw")
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.login("alice", "pw")))
        XCTAssertEqual(app.whoami?.user, "u")
        XCTAssertFalse(app.isReadOnly)
    }

    func testViewerIsReadOnly() async {
        let mock = MockHestiaAPI()
        await mock.setWhoami(role: "viewer")
        let app = AppState(api: mock)
        await app.login(user: "v", password: "pw")
        XCTAssertTrue(app.isReadOnly)
    }

    func testSignOut() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.signOut()
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.logout))
        XCTAssertNil(app.whoami)
        XCTAssertEqual(app.phase, .needsAuth)
    }
}
