import Foundation
import os

/// Persistent runtime override for the hestia backend base URL.
///
/// Vesta has no hard-coded server: the user enters one in ``ConnectView`` and
/// can change it later. The effective URL resolves as `override ?? bundled`,
/// where `bundled` is the ``Configuration.plist`` `BaseURL` and `override` is a
/// validated string in `UserDefaults`. ``AppConfig/serverURL`` reads through
/// this store so the API client and event stream pick up a change on their next
/// URL evaluation.
///
/// Concurrency: `@unchecked Sendable`; mutable state lives behind an
/// `OSAllocatedUnfairLock` so the synchronous getter is callable from
/// `@Sendable` contexts without hopping actors.
///
/// Trust boundary: persisted strings are re-validated via ``canonicalize(_:)``
/// on load; a corrupted entry is cleared and the bundled default takes over.
final class BackendURLStore: @unchecked Sendable {

    static let shared = BackendURLStore(userDefaults: .standard)

    static let userDefaultsKey = "vesta.customBackendURL"

    /// Fallback used only when ``Configuration.plist`` is missing/unparsable
    /// (e.g. a test bundle). Real builds always read the plist.
    static let compiledInFallbackURLString = "http://localhost:8080"

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ie.klatt.vesta",
                                       category: "BackendURLStore")

    private struct State: Sendable {
        var bundledBaseURL: URL
        var override: URL?
        var effective: URL { override ?? bundledBaseURL }
    }

    private let userDefaults: UserDefaults
    private let lock: OSAllocatedUnfairLock<State>

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        let bundled = Self.loadBundledBaseURL()
        let override = Self.loadValidatedOverride(from: userDefaults)
        self.lock = OSAllocatedUnfairLock(initialState: State(bundledBaseURL: bundled, override: override))
    }

    /// Effective backend URL (override if set, else bundled). Always valid.
    func currentEffectiveURL() -> URL { lock.withLock { $0.effective } }

    func bundledBaseURL() -> URL { lock.withLock { $0.bundledBaseURL } }

    func hasOverride() -> Bool { lock.withLock { $0.override != nil } }

    /// Persist a canonicalized override. Callers MUST pass a value that came
    /// from ``canonicalize(_:)``.
    func saveOverride(_ url: URL) {
        lock.withLock { $0.override = url }
        userDefaults.set(url.absoluteString, forKey: Self.userDefaultsKey)
    }

    /// Drop any override and revert to the bundled default. Idempotent.
    func clearOverride() {
        lock.withLock { $0.override = nil }
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
    }

    /// Canonicalize raw user input into an origin-only backend base URL.
    ///
    /// - Trims whitespace; lowercases scheme + host (RFC 3986).
    /// - Rejects path / query / fragment / userinfo (origin only, so the
    ///   generated client's path templating slots in cleanly).
    /// - `https://` is always accepted. `http://` is accepted only for
    ///   loopback and RFC 1918 / `.local` LAN hosts — a hestia box at home is
    ///   typically plain-http on the LAN, which `NSAllowsLocalNetworking`
    ///   permits without weakening ATS for public hosts. Public `http://` is
    ///   rejected.
    /// - Returns `nil` on any rejection; the editor surfaces a message.
    static func canonicalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        components.scheme = scheme

        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        components.host = host

        if scheme == "http", !isLANHost(host) { return nil }

        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }

        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" else { return nil }
        components.percentEncodedPath = ""

        return components.url
    }

    /// Loopback or private/LAN host where plain http is acceptable.
    static func isLANHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count == 4, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    private static func loadBundledBaseURL() -> URL {
        guard
            let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let raw = dict["BaseURL"] as? String, !raw.isEmpty,
            let baseURL = URL(string: raw)
        else {
            logger.error("Configuration.plist missing/unparsable; using compiled-in fallback.")
            assertionFailure("Configuration.plist missing or unparsable.")
            return URL(string: compiledInFallbackURLString)!
        }
        return baseURL
    }

    private static func loadValidatedOverride(from defaults: UserDefaults) -> URL? {
        guard let raw = defaults.string(forKey: userDefaultsKey) else { return nil }
        guard let canonical = canonicalize(raw) else {
            logger.warning("Persisted backend URL failed re-validation; clearing.")
            defaults.removeObject(forKey: userDefaultsKey)
            return nil
        }
        return canonical
    }
}
