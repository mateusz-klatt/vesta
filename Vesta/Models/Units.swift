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

/// How a blind position should read: fully lowered, fully raised, or a %.
enum BlindState: Equatable {
    case lowered
    case raised
    case partial(Int)

    static func from(percent: Int) -> BlindState {
        if percent <= 0 { return .lowered }
        if percent >= 100 { return .raised }
        return .partial(percent)
    }
}

enum Lang {
    /// Whether a BCP-47 language code is written right-to-left (ar/fa/he/…).
    static func isRTL(_ code: String) -> Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }

    /// The language's own name (autonym), e.g. de → "Deutsch", ja → "日本語".
    static func autonym(_ code: String) -> String {
        let name = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A representative flag emoji for the language (best-effort country).
    static func flag(_ code: String) -> String {
        guard let region = regionByLanguage[code] else { return "🌐" }
        return region.unicodeScalars.reduce(into: "") { acc, scalar in
            if let flagScalar = Unicode.Scalar(127_397 + scalar.value) { acc.unicodeScalars.append(flagScalar) }
        }
    }

    private static let regionByLanguage: [String: String] = [
        "ar": "SA", "bn": "BD", "bs": "BA", "cs": "CZ", "da": "DK", "de": "DE",
        "el": "GR", "en": "GB", "es": "ES", "fa": "IR", "fi": "FI", "fil": "PH",
        "fr": "FR", "ga": "IE", "he": "IL", "hi": "IN", "hr": "HR", "hu": "HU",
        "hy": "AM", "id": "ID", "is": "IS", "it": "IT", "ja": "JP", "ko": "KR",
        "lt": "LT", "lv": "LV", "ms": "MY", "my": "MM", "nb": "NO", "nl": "NL",
        "pl": "PL", "pt-BR": "BR", "ro": "RO", "ru": "RU", "sk": "SK", "sq": "AL",
        "sr-Latn": "RS", "sv": "SE", "sw": "KE", "th": "TH", "tr": "TR", "uk": "UA",
        "vi": "VN", "zh-Hans": "CN", "zh-Hant": "TW",
    ]
}
