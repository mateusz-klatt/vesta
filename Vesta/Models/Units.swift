import Foundation

/// Display unit for temperatures. The control protocol is always Celsius; this
/// only affects how values are shown.
enum TempScale: String, CaseIterable, Sendable, Identifiable {
    case celsius = "C"
    case fahrenheit = "F"
    var id: String { rawValue }
}

enum Units {
    /// Format an ambient/measured temperature (Celsius) in the chosen scale.
    static func format(_ celsius: Double, scale: TempScale) -> String {
        switch scale {
        case .celsius: return String(format: "%.1f°", celsius)
        case .fahrenheit: return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }

    /// Format an integer setpoint (Celsius) in the chosen scale.
    static func format(setpoint celsius: Int, scale: TempScale) -> String {
        switch scale {
        case .celsius: return "\(celsius)°"
        case .fahrenheit: return "\(Int((Double(celsius) * 9 / 5 + 32).rounded()))°F"
        }
    }
}

/// Pure control-math helpers (extracted so they are unit-testable).
enum Control {
    /// Map a 0…100 % UI position to hestia's 0…99 cover value.
    static func coverValue(percent: Int) -> Int {
        Int((Double(max(0, min(100, percent))) / 100.0 * 99.0).rounded())
    }

    /// Map hestia's 0…99 cover value back to a 0…100 % position.
    static func coverPercent(value: Int) -> Int {
        Int((Double(max(0, min(99, value))) / 99.0 * 100.0).rounded())
    }

    /// The idempotent A/C IR signal name, e.g. `on_cool_22`.
    static func klimaButton(mode: String, temp: Int) -> String {
        "on_\(mode)_\(temp)"
    }

    /// Roles that may only observe (controls disabled).
    static func isReadOnly(role: String?) -> Bool {
        role == "viewer"
    }
}
