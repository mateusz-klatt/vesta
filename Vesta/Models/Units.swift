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
    // Blind position scale — the mapping between hestia's wire `cover` value (0–99,
    // what the device speaks) and the displayed openness % on the slider. Deliberately
    // NON-LINEAR to match how venetian blinds open: the slats stack/curl as the blind
    // raises, so perceived openness LAGS the wire value (commanding ~64 looks half-open).
    // The bottom is a dead-zone — wire 0 is the only fully-closed/opaque state, any small
    // lift (≈ wire 10) already lets light through, and 1–9 look the same. Ported one-for-one
    // from hestia's ui/src/render/cover.ts so Vesta's slider reads the same % as the web UI
    // (the low-level `cover` op itself stays raw wire 0–99).
    private static let blindVisibleWire = 10.0                       // smallest wire "open a crack" (1–9 look identical)
    private static let blindOpenWire = 99.0                          // fully open
    private static let blindSpan = blindOpenWire - blindVisibleWire  // 89
    private static let blindExp = 1.4                                // perceived-openness curve; >1 because openness lags wire

    /// Map a 0…100 % UI position to hestia's 0…99 cover value.
    static func coverValue(percent: Int) -> Int {
        let p = Double(max(0, min(100, percent)))
        if p <= 0 { return 0 }                          // fully closed
        if p <= 1 { return Int(blindVisibleWire) }      // first step above closed → the see-through crack
        return Int((blindVisibleWire + blindSpan * pow((p - 1) / 99, 1 / blindExp)).rounded())
    }

    /// Map hestia's 0…99 cover value back to a 0…100 % position.
    static func coverPercent(value: Int) -> Int {
        let w = Double(max(0, min(99, value)))
        if w <= 0 { return 0 }                          // fully closed, opaque
        let t = min(1, max(0, (w - blindVisibleWire) / blindSpan))  // 1–9 → 0 → the 1 % floor
        return Int((1 + 99 * pow(t, blindExp)).rounded())
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

/// A multi-gang switch's individual channels (e.g. a 2-gang wall plate where one
/// rocker is the ceiling light and the other a wall lamp). A plain single-gang
/// device has no `endpoints` and is driven by its aggregate `switch` instead.
enum Gangs {
    struct Gang: Equatable, Identifiable {
        let key: Int        // hestia endpoint channel (1 or 2)
        let name: String    // server-defined channel name, may be empty
        let on: Bool
        var id: Int { key }
    }

    /// Ordered channels for a device, or `[]` when it's a single-gang switch.
    static func list(states: [String: Bool]?, names: [String: String]?) -> [Gang] {
        guard let states, !states.isEmpty else { return [] }
        let names = names ?? [:]
        return states.keys
            .compactMap(Int.init)
            .sorted()
            .map { Gang(key: $0, name: names[String($0)] ?? "", on: states[String($0)] ?? false) }
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
