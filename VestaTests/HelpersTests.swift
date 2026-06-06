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

    func testCoverValueClampsAndMaps() {
        XCTAssertEqual(Control.coverValue(percent: 0), 0)
        XCTAssertEqual(Control.coverValue(percent: 100), 99)
        XCTAssertEqual(Control.coverValue(percent: -20), 0)
        XCTAssertEqual(Control.coverValue(percent: 250), 99)
        XCTAssertEqual(Control.coverValue(percent: 50), 50)   // 49.5 → 50
    }

    func testCoverPercentRoundTrips() {
        XCTAssertEqual(Control.coverPercent(value: 0), 0)
        XCTAssertEqual(Control.coverPercent(value: 99), 100)
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
