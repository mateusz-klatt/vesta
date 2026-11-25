import Foundation
import OpenAPIRuntime
import XCTest

// This target generates its client from the unchanged v1.1.0 contract.
final class Legacy110ContractTests: XCTestCase {
    func testBearerLoginDecodesLegacySuccess() async throws {
        let client = contractClient(["POST /api/login": #"{"ok":true,"user":"viewer","token":"fake-session-token"}"#]) {
            _, body in
            let data = try await Data(collecting: try XCTUnwrap(body), upTo: 1024)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["bearer"] as? Bool, true)
        }
        let result = try await client.login(.init(body: .json(.init(
            bearer: true, password: "fake-password", user: "viewer"
        )))).ok.body.json
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.user, "viewer")
        XCTAssertEqual(result.token, "fake-session-token")
    }

    func testWhoamiDecodesAllLegacyRolesAndAuthOff() async throws {
        for role in ["viewer", "operator", "admin"] {
            let client = contractClient(["GET /api/whoami": #"{"user":"demo","role":"\#(role)"}"#])
            let identity = try await client.whoami(.init()).ok.body.json
            XCTAssertEqual(identity.user, "demo")
            XCTAssertEqual(identity.role, role)
        }
        let client = contractClient(["GET /api/whoami": #"{"user":null,"role":null}"#])
        let identity = try await client.whoami(.init()).ok.body.json
        XCTAssertNil(identity.user)
        XCTAssertNil(identity.role)
    }

    func testUserRowsKeepRequiredRole() async throws {
        let client = contractClient(["GET /api/users": """
        {"users":[{"username":"viewer","role":"viewer","disabled":false},
                  {"username":"operator","role":"operator","disabled":true},
                  {"username":"admin","role":"admin","disabled":false}]}
        """])
        let results = try await client.listUsers(.init()).ok.body.json
        XCTAssertEqual(results.users.map(\.role), [.viewer, ._operator, .admin])
        XCTAssertEqual(results.users.map(\.disabled), [false, true, false])

        let missingRole = contractClient(["GET /api/users": #"{"users":[{"username":"viewer","disabled":false}]}"#])
        do {
            _ = try await missingRole.listUsers(.init()).ok.body.json
            XCTFail("UserRow.role must remain required")
        } catch let error as ClientError {
            guard case DecodingError.keyNotFound(let key, _) = error.underlyingError else {
                return XCTFail("Expected the missing role to fail decoding, received \(error.underlyingError)")
            }
            XCTAssertEqual(key.stringValue, "role")
        }
    }

    func testDiscoveryAndControlDecodeLegacyBodies() async throws {
        let client = contractClient([
            "GET /api/discovery": """
            {"devices":{},"summary":{"total":0,"confirmed":0,"unknown":0},
             "globals":{"crib_temp":null,"crib_temp_ts":null,"outdoor_battery_ok":null,
                        "outdoor_humidity":null,"outdoor_temp":null,"outdoor_temp_ts":null},
             "ir_buttons":[],"klima":{},"klima_state":null,"mode":"home","target_mode":"home",
             "env_override":null,
             "rule_vocab":{"trigger_types":[],"state_fields":{},"cmp_ops":[],"frame_action_ops":[],
                           "modes":["home"],"sun_events":[],"presence_events":[],"condition_types":[]}}
            """,
            "POST /api/control": #"{"ok":true,"sent":"7e00"}"#,
            "POST /api/scene": #"{"ok":true,"sent":2,"total":3}"#,
            "POST /api/ir": #"{"ok":true}"#,
        ])
        let discovery = try await client.discovery(.init()).ok.body.json
        XCTAssertEqual(discovery.mode, "home")
        XCTAssertEqual(discovery.summary.total, 0)
        XCTAssertNil(discovery.globals.outdoorTemp)

        let control = try await client.control(.init(body: .json(
            ._switch(.init(node: 1, on: true, op: ._switch))
        ))).ok.body.json
        XCTAssertTrue(control.ok)
        XCTAssertEqual(control.sent, "7e00")

        let scene = try await client.scene(.init(body: .json(.init(op: .lightsOff)))).ok.body.json
        XCTAssertTrue(scene.ok)
        XCTAssertEqual(scene.sent, 2)
        XCTAssertEqual(scene.total, 3)

        let ir = try await client.ir(.init(body: .json(.init(button: "off", file: "sample.ir")))).ok.body.json
        XCTAssertTrue(ir.ok)
    }
}
