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
    private var discoveryResult: Components.Schemas.Discovery?

    func setWhoami(role: String?) { whoamiResult = .init(role: role, user: "u") }
    func setDiscovery(_ discovery: Components.Schemas.Discovery) { discoveryResult = discovery }

    func whoami() async throws -> Components.Schemas.WhoAmI { calls.append(.whoami); return whoamiResult }
    func discovery() async throws -> Components.Schemas.Discovery {
        calls.append(.discovery)
        if let discoveryResult { return discoveryResult }
        throw APIError.http(599)
    }
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

    private func makeDiscovery(_ devices: [String: Components.Schemas.DeviceInfo]) -> Components.Schemas.Discovery {
        .init(
            devices: .init(additionalProperties: devices),
            globals: .init(cribTemp: 21, outdoorHumidity: 50, outdoorTemp: 10),
            irButtons: [],
            klima: .init(file: "k.ir", powerOn: .init(additionalProperties: ["cool": [18, 19, 20]]), presets: ["off"]),
            klimaState: .init(mode: "cool", power: false, temp: 20),
            mode: "standalone",
            ruleVocab: .init(cmpOps: [], conditionTypes: [], frameActionOps: [], modes: [],
                             presenceEvents: [], stateFields: .init(), sunEvents: [], triggerTypes: []),
            summary: .init(confirmed: 0, total: devices.count, unknown: 0),
            targetMode: "standalone"
        )
    }

    func testLoadDiscoveryPopulatesState() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "1": .init(_switch: true, _type: "light"),
            "2": .init(_type: "blind"),
            "3": .init(setpoint: 20, thermostatOn: true, _type: "thermostat"),
        ]))
        let app = AppState(api: mock)
        await app.loadDiscovery()
        XCTAssertEqual(app.phase, .ready)
        XCTAssertFalse(app.rooms.isEmpty)
        XCTAssertNotNil(app.klima)
        XCTAssertTrue(app.hasLights)
        XCTAssertTrue(app.hasBlinds)
    }

    func testAllLightsBulkHitsEveryLight() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "1": .init(_switch: false, _type: "light"),
            "7": .init(_switch: false, _type: "light"),
            "2": .init(_type: "blind"),
        ]))
        let app = AppState(api: mock)
        await app.loadDiscovery()
        await app.allLights(on: true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(1, true, nil)))
        XCTAssertTrue(calls.contains(.setSwitch(7, true, nil)))
    }

    func testAllLightsHitsEveryGangOfMultiGang() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery([
            "3": .init(_switch: false, _type: "light"),  // single-gang
            "7": .init(endpointNames: .init(additionalProperties: ["1": "duże", "2": "małe"]),
                       endpoints: .init(additionalProperties: ["1": true, "2": false]),
                       _switch: true, _type: "light"),    // 2-gang
        ]))
        let app = AppState(api: mock)
        await app.loadDiscovery()
        await app.allLights(on: true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(3, true, nil)))   // single → no endpoint
        XCTAssertTrue(calls.contains(.setSwitch(7, true, 1)))     // each gang addressed
        XCTAssertTrue(calls.contains(.setSwitch(7, true, 2)))
        XCTAssertFalse(calls.contains(.setSwitch(7, true, nil)))  // never the bogus aggregate
    }

    func testToggleGangSendsEndpoint() async {
        let mock = MockHestiaAPI()
        let app = AppState(api: mock)
        await app.toggle(device("7", type: "light"), on: false, endpoint: 2)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setSwitch(7, false, 2)))
    }

    func testAllBlindsBulk() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["2": .init(_type: "blind"), "5": .init(_type: "blind")]))
        let app = AppState(api: mock)
        await app.loadDiscovery()
        await app.allBlinds(up: true)
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.setCover(2, 99)))
        XCTAssertTrue(calls.contains(.setCover(5, 99)))
    }

    func testKlimaSetSendsIR() async {
        let mock = MockHestiaAPI()
        await mock.setDiscovery(makeDiscovery(["1": .init(_switch: true, _type: "light")]))
        let app = AppState(api: mock)
        await app.loadDiscovery()
        await app.klimaSet(mode: "cool", temp: 20)
        await app.klimaOff()
        let calls = await mock.calls
        XCTAssertTrue(calls.contains(.sendIR("k.ir", "on_cool_20")))
        XCTAssertTrue(calls.contains(.sendIR("k.ir", "off")))
    }

    func testBootstrapUnconfiguredWhenNoOverride() async {
        BackendURLStore.shared.clearOverride()
        let app = AppState(api: MockHestiaAPI())
        await app.bootstrap()
        XCTAssertEqual(app.phase, .unconfigured)
    }

    func testRoomGroupGroupsByRoom() {
        let discovery = makeDiscovery([
            "1": .init(name: "Lamp", room: "Salon", _type: "light"),
            "2": .init(room: "Salon", _type: "blind"),
            "9": .init(room: "Kitchen", _type: "thermostat"),
        ])
        let groups = RoomGroup.group(discovery)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.name).sorted(), ["Kitchen", "Salon"])
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
