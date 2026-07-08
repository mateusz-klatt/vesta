import XCTest
import Foundation
@testable import Vesta

final class UnitsTests: XCTestCase {

    func testFormatCelsius() {
        XCTAssertEqual(Units.format(21.5, scale: .celsius), "21.5°")
        XCTAssertEqual(Units.format(0, scale: .celsius), "0.0°")
    }

    func testFormatFahrenheit() {
        XCTAssertEqual(Units.format(0, scale: .fahrenheit), "32°F")
        XCTAssertEqual(Units.format(100, scale: .fahrenheit), "212°F")
        XCTAssertEqual(Units.format(21, scale: .fahrenheit), "70°F")
    }

    func testFormatSetpoint() {
        XCTAssertEqual(Units.format(setpoint: 22, scale: .celsius), "22°")
        XCTAssertEqual(Units.format(setpoint: 20, scale: .fahrenheit), "68°F")
    }
}

final class ControlMathTests: XCTestCase {

    // The perceptual blind curve — same anchors as hestia's cover.test.ts so the two
    // clients agree on what a given slider position means for the same physical blind.
    func testCoverPercentMapsOperatorAnchors() {
        XCTAssertEqual(Control.coverPercent(value: 0), 0)    // fully closed, opaque
        XCTAssertEqual(Control.coverPercent(value: 5), 1)    // dead-zone 1…9 reads as the 1 % crack
        XCTAssertEqual(Control.coverPercent(value: 10), 1)   // first see-through crack
        XCTAssertEqual(Control.coverPercent(value: 50), 33)  // looks ~1/3 open
        XCTAssertEqual(Control.coverPercent(value: 64), 50)  // looks ~half open
        XCTAssertEqual(Control.coverPercent(value: 99), 100) // fully open
    }

    func testCoverValueMapsOperatorAnchors() {
        XCTAssertEqual(Control.coverValue(percent: 0), 0)    // closed
        XCTAssertEqual(Control.coverValue(percent: 1), 10)   // first step above closed → the crack (never wire 1…9)
        XCTAssertEqual(Control.coverValue(percent: 50), 64)  // drag to half → physically ~half
        XCTAssertEqual(Control.coverValue(percent: 100), 99) // fully open
    }

    func testCoverValueNeverCommandsTheDeadZone() {
        for percent in 0...100 {
            let wire = Control.coverValue(percent: percent)
            XCTAssertTrue(wire == 0 || wire >= 10, "percent \(percent) mapped to dead-zone wire \(wire)")
        }
    }

    func testCoverScaleIsMonotonicBothDirections() {
        var prevWire = -1
        for percent in 0...100 {
            let wire = Control.coverValue(percent: percent)
            XCTAssertGreaterThanOrEqual(wire, prevWire)
            prevWire = wire
        }
        var prevPercent = -1
        for wire in 0...99 {
            let percent = Control.coverPercent(value: wire)
            XCTAssertGreaterThanOrEqual(percent, prevPercent)
            prevPercent = percent
        }
    }

    func testCoverScaleClampsOutOfRange() {
        XCTAssertEqual(Control.coverPercent(value: -5), 0)
        XCTAssertEqual(Control.coverPercent(value: 200), 100)
        XCTAssertEqual(Control.coverValue(percent: -20), 0)
        XCTAssertEqual(Control.coverValue(percent: 250), 99)
    }

    func testKlimaButton() {
        XCTAssertEqual(Control.klimaButton(mode: "cool", temp: 22), "on_cool_22")
        XCTAssertEqual(Control.klimaButton(mode: "heat", temp: 18), "on_heat_18")
    }

    func testIsReadOnly() {
        XCTAssertTrue(Control.isReadOnly(role: "viewer"))
        XCTAssertFalse(Control.isReadOnly(role: "operator"))
        XCTAssertFalse(Control.isReadOnly(role: "admin"))
        XCTAssertFalse(Control.isReadOnly(role: nil))
    }
}

final class BlindStateTests: XCTestCase {
    func testFromPercent() {
        XCTAssertEqual(BlindState.from(percent: 0), .lowered)
        XCTAssertEqual(BlindState.from(percent: -5), .lowered)
        XCTAssertEqual(BlindState.from(percent: 100), .raised)
        XCTAssertEqual(BlindState.from(percent: 140), .raised)
        XCTAssertEqual(BlindState.from(percent: 42), .partial(42))
    }
}

final class GangsTests: XCTestCase {
    func testSingleGangIsEmpty() {
        XCTAssertTrue(Gangs.list(states: nil, names: nil).isEmpty)
        XCTAssertTrue(Gangs.list(states: [:], names: ["1": "x"]).isEmpty)
    }

    func testMultiGangOrderedByChannel() {
        let gangs = Gangs.list(states: ["2": true, "1": false],
                               names: ["1": "ceiling", "2": "lamp"])
        XCTAssertEqual(gangs, [
            Gangs.Gang(key: 1, name: "ceiling", on: false),
            Gangs.Gang(key: 2, name: "lamp", on: true),
        ])
    }

    func testMissingNameFallsBackToEmpty() {
        let gangs = Gangs.list(states: ["1": true], names: nil)
        XCTAssertEqual(gangs, [Gangs.Gang(key: 1, name: "", on: true)])
    }
}

final class LangTests: XCTestCase {
    func testIsRTL() {
        XCTAssertTrue(Lang.isRTL("ar"))
        XCTAssertTrue(Lang.isRTL("he"))
        XCTAssertTrue(Lang.isRTL("fa"))
        XCTAssertFalse(Lang.isRTL("en"))
        XCTAssertFalse(Lang.isRTL("pl"))
        XCTAssertFalse(Lang.isRTL("ja"))
    }

    func testFlag() {
        XCTAssertEqual(Lang.flag("de"), "🇩🇪")
        XCTAssertEqual(Lang.flag("pl"), "🇵🇱")
        XCTAssertEqual(Lang.flag("pt-BR"), "🇧🇷")
        XCTAssertEqual(Lang.flag("zh-Hant"), "🇹🇼")
        XCTAssertEqual(Lang.flag("xx-nope"), "🌐")
    }

    func testAutonym() {
        XCTAssertEqual(Lang.autonym("de"), "Deutsch")
        XCTAssertEqual(Lang.autonym("pl"), "Polski")
        XCTAssertFalse(Lang.autonym("ja").isEmpty)
    }
}

final class APIErrorTests: XCTestCase {

    func testWrapMapsURLErrorCodes() {
        XCTAssertEqual(APIError.wrap(URLError(.cannotFindHost)), .serverNotFound)
        XCTAssertEqual(APIError.wrap(URLError(.dnsLookupFailed)), .serverNotFound)
        XCTAssertEqual(APIError.wrap(URLError(.timedOut)), .timedOut)
        XCTAssertEqual(APIError.wrap(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(APIError.wrap(URLError(.secureConnectionFailed)), .tls)
        XCTAssertEqual(APIError.wrap(URLError(.cannotConnectToHost)), .cannotConnect)
    }

    func testWrapPassesThroughAPIError() {
        XCTAssertEqual(APIError.wrap(APIError.unauthorized), .unauthorized)
        XCTAssertEqual(APIError.wrap(APIError.http(500)), .http(500))
    }

    func testWrapUnknownBecomesUnexpectedWithDetail() {
        let wrapped = APIError.wrap(URLError(.badURL))
        guard case .unexpected = wrapped else { return XCTFail("expected .unexpected") }
        XCTAssertNotNil(wrapped.technical)
    }

    func testEveryErrorHasTitleAndMessage() {
        let cases: [APIError] = [.unauthorized, .serverNotFound, .timedOut, .offline, .tls, .cannotConnect, .http(503), .unexpected("x")]
        for error in cases {
            XCTAssertFalse(String(localized: error.title).isEmpty)
            XCTAssertFalse(String(localized: error.message).isEmpty)
        }
    }
}
