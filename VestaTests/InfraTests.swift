import XCTest
import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import Vesta

final class PrivacyLocalizationTests: XCTestCase {
    func testLocalNetworkPurposeIsBundledForEverySupportedLanguage() throws {
        let bundle = Bundle.main
        let locales = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        )
        XCTAssertFalse(locales.isEmpty)
        for locale in locales {
            // Read the exact locale file so English fallback cannot hide a
            // missing catalog resource in the generated app bundle.
            let url = bundle.bundleURL.appendingPathComponent("\(locale).lproj/InfoPlist.strings")
            let data = try Data(contentsOf: url)
            let values = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    as? [String: String],
                locale
            )
            for key in ["NSLocalNetworkUsageDescription", "NSCameraUsageDescription"] {
                let purpose = try XCTUnwrap(values[key], "\(locale) \(key)")
                XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(locale) \(key)")
            }
        }
    }
}

final class CatalogCompletenessTests: XCTestCase {
    @MainActor
    func testCatalogsCoverEveryPickerLanguage() throws {
        // Read source catalogs: compiled strings and Bundle localization APIs
        // can silently fall back to English and conceal missing translations.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let languages = SettingsView.languages
        XCTAssertEqual(Set(languages).count, languages.count)
        XCTAssertEqual(Set(languages), Set(try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        )))
        for name in ["Localizable", "InfoPlist"] {
            let url = root.appendingPathComponent("Vesta/\(name).xcstrings")
            let catalog = try JSONDecoder().decode(StringCatalog.self, from: Data(contentsOf: url))
            let locales = Set(catalog.strings.values.flatMap { Array($0.localizations.keys) })
                .union([catalog.sourceLanguage])
            XCTAssertEqual(locales, Set(languages), name)
            XCTAssertEqual(catalog.issues(languages: languages), [], name)
        }
    }

    func testImplicitEnglishSourceAndUntranslatableEntriesAreAllowed() {
        let catalog = StringCatalog(sourceLanguage: "en", strings: [
            "Hello %@": .init(localizations: ["pl": .text("Witaj %@")]),
            "Vesta": .init(shouldTranslate: false),
        ])
        XCTAssertEqual(catalog.issues(languages: ["en", "pl"]), [])
    }

    func testMissingUntranslatedAndEmptyTranslationsAreRejected() {
        let translations: [CatalogLocalization?] = [nil, .text("Witaj %@", state: "new"), .text(" \n")]
        for translation in translations {
            let catalog = fixture(source: "Hello %@", translation: translation)
            XCTAssertFalse(catalog.issues(languages: ["en", "pl"]).isEmpty)
        }
    }

    func testPlaceholdersPreserveArgumentPositionsTypesAndCounts() {
        let source = "%@ owes %lld (100%%)"
        XCTAssertEqual(fixture(source: source, translation: .text("%2$lld: %1$@ (100%%)"))
            .issues(languages: ["pl"]), [])
        for value in ["%@", "%@ %ld", "%@ %lld %lld", "%2$@ %1$lld", "%1$@ %1$@", "%0$@ %2$lld"] {
            XCTAssertFalse(fixture(source: source, translation: .text(value))
                .issues(languages: ["pl"]).isEmpty, value)
        }
    }

    func testPluralBranchesUseTheirEnglishCounterpartOrOther() {
        let english = CatalogLocalization(variations: ["plural": [
            "one": .text("One item for %@"), "other": .text("%lld items for %@"),
        ]])
        let translated = CatalogLocalization(variations: ["plural": [
            "one": .text("Jeden produkt dla %@"),
            "few": .text("Dla %2$@: %1$lld produkty"),
            "other": .text("%lld produktów dla %@"),
        ]])
        let catalog = StringCatalog(sourceLanguage: "en", strings: [
            "%lld items for %@": .init(localizations: ["en": english, "pl": translated]),
        ])
        XCTAssertEqual(catalog.issues(languages: ["en", "pl"]), [])
        // Languages without plural inflection can use a flat stringUnit. Its
        // arguments must match English's other branch, including nested axes.
        for source in [english, .init(variations: ["device": ["other": english]])] {
            let flat = StringCatalog(sourceLanguage: "en", strings: [
                "%lld items for %@": .init(localizations: [
                    "en": source, "zh-Hans": .text("%2$@的%1$lld件商品"),
                ]),
            ])
            XCTAssertEqual(flat.issues(languages: ["zh-Hans"]), [])
        }
    }

    func testEmptyMissingAndInvalidVariationBranchesAreRejected() {
        for translation in [
            CatalogLocalization(variations: [:]),
            .init(variations: ["plural": [:]]),
            .init(variations: ["plural": ["one": .text("%lld produkt")]]),
            .init(variations: ["plural": ["other": .init()]]),
            .init(variations: ["plural": ["other": .text("%lld produktów", state: "needs_review")]]),
            .init(variations: ["plural": ["one": .text("%@ produkt"), "other": .text("%lld produktów")]]),
        ] {
            XCTAssertFalse(fixture(source: "%lld items", translation: translation)
                .issues(languages: ["pl"]).isEmpty)
        }
    }

    private func fixture(source: String, translation: CatalogLocalization?) -> StringCatalog {
        StringCatalog(sourceLanguage: "en", strings: [
            source: .init(localizations: translation.map { ["pl": $0] } ?? [:]),
        ])
    }
}

private struct StringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: CatalogEntry]

    func issues(languages: [String]) -> [String] {
        var issues: [String] = []
        for (key, entry) in strings.sorted(by: { $0.key < $1.key }) where entry.shouldTranslate != false {
            // Xcode omits the source stringUnit when the key itself is English.
            let source = entry.localizations[sourceLanguage] ?? .text(key)
            for language in languages {
                let context = "\(language): \(key)"
                guard let translated = entry.localizations[language] ?? (language == sourceLanguage ? source : nil) else {
                    issues.append("\(context): missing localization")
                    continue
                }
                translated.validate(source: source, context: context, issues: &issues)
            }
        }
        return issues
    }
}

private struct CatalogEntry: Decodable {
    var shouldTranslate: Bool? = nil
    var localizations: [String: CatalogLocalization] = [:]

    private enum CodingKeys: String, CodingKey { case shouldTranslate, localizations }

    init(shouldTranslate: Bool? = nil, localizations: [String: CatalogLocalization] = [:]) {
        self.shouldTranslate = shouldTranslate
        self.localizations = localizations
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        shouldTranslate = try values.decodeIfPresent(Bool.self, forKey: .shouldTranslate)
        localizations = try values.decodeIfPresent([String: CatalogLocalization].self, forKey: .localizations) ?? [:]
    }
}

private struct CatalogLocalization: Decodable {
    struct Unit: Decodable {
        let state: String
        let value: String
    }
    var stringUnit: Unit? = nil
    var variations: [String: [String: CatalogLocalization]]? = nil

    static func text(_ value: String, state: String = "translated") -> Self {
        .init(stringUnit: .init(state: state, value: value))
    }

    func validate(source: Self, context: String, issues: inout [String]) {
        if let stringUnit {
            if stringUnit.state != "translated" || stringUnit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("\(context): empty or untranslated stringUnit")
            }
            let english = source.defaultUnits
            if !english.isEmpty {
                do {
                    let translated = try Self.placeholders(stringUnit.value)
                    for unit in english where try Self.placeholders(unit.value) != translated {
                        issues.append("\(context): placeholders differ from English")
                    }
                } catch {
                    issues.append("\(context): invalid format placeholders")
                }
            } else {
                issues.append("\(context): missing English variation counterpart")
            }
        }
        if let variations {
            if variations.isEmpty { issues.append("\(context): empty variations") }
            for (dimension, branches) in variations.sorted(by: { $0.key < $1.key }) {
                if branches.isEmpty || (dimension == "plural" && branches["other"] == nil) {
                    issues.append("\(context)/\(dimension): empty variations or missing other branch")
                }
                for (name, branch) in branches.sorted(by: { $0.key < $1.key }) {
                    let english = source.variations?[dimension]?[name]
                        ?? source.variations?[dimension]?["other"] ?? source
                    branch.validate(source: english, context: "\(context)/\(dimension)/\(name)", issues: &issues)
                }
            }
        } else if stringUnit == nil {
            issues.append("\(context): missing stringUnit or variations")
        }
    }

    private var defaultUnits: [Unit] {
        if let stringUnit { return [stringUnit] }
        guard let variations, !variations.isEmpty else { return [] }
        let defaults = variations.values.map { $0["other"]?.defaultUnits ?? [] }
        guard defaults.allSatisfy({ !$0.isEmpty }) else { return [] }
        return defaults.flatMap { $0 }
    }

    /// Compare each argument's index, type, and occurrence count, allowing a
    /// translator to reorder positional specifiers without swapping their types.
    private static func placeholders(_ value: String) throws -> [Int: [String]] {
        let pattern = #"%(?:(\d+)\$)?[-+#0 ']*(?:(\*(?:(\d+)\$)?)|\d+)?(?:\.(?:(\*(?:(\d+)\$)?)|\d+))?(hh|ll|h|l|q|L|z|t|j)?([@diuoxXfFeEgGaAcCsSpn%])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = value as NSString
        var arguments: [Int: [String]] = [:]
        var nextIndex = 1
        var explicit = false
        var implicit = false
        enum InvalidFormat: Error { case argumentIndex }
        func add(_ position: String, type: String) throws {
            let index: Int
            if position.isEmpty {
                implicit = true
                index = nextIndex
                nextIndex += 1
            } else {
                explicit = true
                guard let parsed = Int(position), parsed > 0 else { throw InvalidFormat.argumentIndex }
                index = parsed
            }
            guard !(explicit && implicit) else { throw InvalidFormat.argumentIndex }
            arguments[index, default: []].append(type)
        }
        for match in regex.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            func group(_ index: Int) -> String {
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : text.substring(with: range)
            }
            guard group(7) != "%" else { continue }
            if !group(2).isEmpty { try add(group(3), type: "d") }
            if !group(4).isEmpty { try add(group(5), type: "d") }
            try add(group(1), type: group(6) + group(7))
        }
        return arguments.mapValues { $0.sorted() }
    }
}

final class HTTPSessionTests: XCTestCase {
    /// hestia sets its session cookie even on a bearer login; Vesta must never
    /// store or replay it next to `Authorization`.
    func testNoCookiesAreStoredOrSent() {
        let configuration = HTTPSession.shared.configuration
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
    }

    func testFeaturesProbeRejectsRedirects() async throws {
        let session = HTTPSession.featuresProbe
        let delegate = try XCTUnwrap(session.delegate as? FeaturesProbeDelegate)
        let url = try XCTUnwrap(URL(string: "https://hestia.example/api/auth/features"))
        let task = session.dataTask(with: url)
        defer { task.cancel() }
        let location = "https://hestia.example/api/whoami"
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": location]
        ))
        let redirect = URLRequest(url: try XCTUnwrap(URL(string: location)))
        let result = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                               newRequest: redirect)
        XCTAssertNil(result)
    }

    func testFeaturesProbeOnlyAllowsDefaultServerTrustHandling() async throws {
        let session = HTTPSession.featuresProbe
        let delegate = try XCTUnwrap(session.delegate as? FeaturesProbeDelegate)
        let url = try XCTUnwrap(URL(string: "https://hestia.example/api/auth/features"))
        let task = session.dataTask(with: url)
        defer { task.cancel() }

        let cases: [(String, URLSession.AuthChallengeDisposition)] = [
            (NSURLAuthenticationMethodHTTPBasic, .rejectProtectionSpace),
            (NSURLAuthenticationMethodHTTPDigest, .rejectProtectionSpace),
            (NSURLAuthenticationMethodClientCertificate, .rejectProtectionSpace),
            (NSURLAuthenticationMethodServerTrust, .performDefaultHandling),
        ]
        for (method, expected) in cases {
            let protectionSpace = URLProtectionSpace(
                host: "hestia.example", port: 443, protocol: "https", realm: nil, authenticationMethod: method
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: protectionSpace, proposedCredential: nil, previousFailureCount: 0,
                failureResponse: nil, error: nil, sender: ProbeChallengeSender()
            )
            let (sessionDisposition, sessionCredential) = await delegate.urlSession(session, didReceive: challenge)
            let (taskDisposition, taskCredential) = await delegate.urlSession(session, task: task, didReceive: challenge)
            XCTAssertEqual(sessionDisposition, expected, method)
            XCTAssertEqual(taskDisposition, expected, method)
            XCTAssertNil(sessionCredential, method)
            XCTAssertNil(taskCredential, method)
        }
    }

    private final class ProbeChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    func testRedirectsStayOnOriginAndReceiptRequestsNeverRedirect() async throws {
        let session = HTTPSession.shared
        let delegate = try XCTUnwrap(session.delegate as? HestiaRedirectDelegate)
        let origin = "https://hestia.example"
        let cases = [
            ("/api/discovery", "https://HESTIA.example:443/api/discovery-v2", true),
            ("/api/events", "\(origin)/api/events-v2", true),
            ("/api/discovery", "http://hestia.example/api/discovery", false),
            ("/api/discovery", "https://other.example/api/discovery", false),
            ("/api/events", "https://hestia.example:8443/api/events", false),
            ("/api/budget/receipts/parse-text", "\(origin)/api/budget/receipts/confirm", false),
        ]
        for (path, location, follows) in cases {
            let url = try XCTUnwrap(URL(string: origin + path))
            let task = session.dataTask(with: url)
            defer { task.cancel() }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": location]
            ))
            let redirect = URLRequest(url: try XCTUnwrap(URL(string: location)))
            let result = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                   newRequest: redirect)
            XCTAssertEqual(result?.url, follows ? redirect.url : nil, "\(path) → \(location)")
        }
    }

    func testBudgetRedirectsAreRejectedInBothDirections() async throws {
        let session = HTTPSession.shared
        let delegate = try XCTUnwrap(session.delegate as? HestiaRedirectDelegate)
        let origin = "https://hestia.example"
        let cases = [
            // Non-budget request redirected into /api/budget or /api/budget/*
            ("/api/discovery", "\(origin)/api/budget", false),
            ("/api/discovery", "\(origin)/api/budget/", false),
            ("/api/discovery", "\(origin)/api/budget/analytics/monthly-budget", false),
            ("/api/discovery", "\(origin)/api/budget/analytics/transactions", false),
            ("/api/discovery", "\(origin)/api/budget/status", false),
            ("/api/discovery", "\(origin)/api/budget/receipts/parse-text", false),
            ("/api/discovery", "\(origin)/api/other/../budget/status", false),
            // Proxy normalization bypasses (MergeSlashes, dot segments, case, encoded slash, backslash)
            ("/api/discovery", "\(origin)//api/budget/status", false),
            ("/api/discovery", "\(origin)/api//budget/status", false),
            ("/api/discovery", "\(origin)/api/./budget/x", false),
            ("/api/discovery", "\(origin)/x/../api/budget/x", false),
            ("/api/discovery", "\(origin)/API/Budget/x", false),
            ("/api/discovery", "\(origin)/api/budget%2Fstatus", false),
            ("/api/discovery", "\(origin)/api%2Fbudget/x", false),
            ("/api/discovery", "\(origin)/api/budget%252Fstatus", false),
            ("/api/discovery", "\(origin)/api/budget%5Cx", false),
            // Budget request redirected out of its allowlist (or anywhere else)
            ("/api/budget", "\(origin)/api/discovery", false),
            ("/api/budget/", "\(origin)/api/discovery", false),
            ("//api/budget/status", "\(origin)/api/discovery", false),
            ("/API/Budget/x", "\(origin)/api/discovery", false),
            ("/api/budget%2Fstatus", "\(origin)/api/discovery", false),
            ("/api/budget/analytics/monthly-budget", "\(origin)/api/discovery", false),
            ("/api/budget/analytics/transactions", "\(origin)/api/events", false),
            ("/api/budget/status", "\(origin)/api/budget/analytics/monthly-budget", false),
            // Prefix boundary: /api/budgeting is not /api/budget or /api/budget/*
            ("/api/discovery", "\(origin)/api/budgeting", true),
            ("/api/discovery", "\(origin)/api//budgeting", true),
        ]
        for (path, location, follows) in cases {
            let url = try XCTUnwrap(URL(string: origin + path))
            let task = session.dataTask(with: url)
            defer { task.cancel() }
            let response = try XCTUnwrap(HTTPURLResponse(
                url: url, statusCode: 307, httpVersion: nil, headerFields: ["Location": location]
            ))
            let redirect = URLRequest(url: try XCTUnwrap(URL(string: location)))
            let result = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                   newRequest: redirect)
            XCTAssertEqual(result?.url, follows ? redirect.url : nil, "\(path) → \(location)")
        }
    }
}

final class TokenStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let keychain = SystemSessionKeychain()
        try keychain.delete(.legacy)
        defer { try? keychain.delete(.legacy) }
        XCTAssertNil(try keychain.read(.legacy))
        let first = Data("abc123".utf8)
        try keychain.write(first, to: .legacy)
        XCTAssertEqual(try keychain.read(.legacy), first)
        let replacement = Data("def456".utf8)
        try keychain.write(replacement, to: .legacy)
        XCTAssertEqual(try keychain.read(.legacy), replacement)
        try keychain.delete(.legacy)
        XCTAssertNil(try keychain.read(.legacy))
    }
}

final class BearerAuthMiddlewareTests: XCTestCase {
    private let origin = URL(string: "https://hestia.example")!

    private func request() -> HTTPRequest {
        HTTPRequest(method: .get, scheme: "https", authority: "hestia.example", path: "/x")
    }

    // `next` is @Sendable, so echo the request's auth header into the response
    // instead of capturing it, then assert on the response.
    func testAddsAuthorizationWhenTokenPresent() async throws {
        let middleware = BearerAuthMiddleware(session: BoundSession(origin: origin, actor: nil, token: "tok"))
        let (response, _) = try await middleware.intercept(
            request(), body: nil, baseURL: origin, operationID: "op"
        ) { req, _, _ in
            var resp = HTTPResponse(status: .ok)
            if let auth = req.headerFields[.authorization] { resp.headerFields[.authorization] = auth }
            return (resp, nil)
        }
        XCTAssertEqual(response.headerFields[.authorization], "Bearer tok")
    }

    func testNoHeaderWhenTokenAbsent() async throws {
        let middleware = BearerAuthMiddleware()
        let (response, _) = try await middleware.intercept(
            request(), body: nil, baseURL: origin, operationID: "op"
        ) { req, _, _ in
            var resp = HTTPResponse(status: .ok)
            if let auth = req.headerFields[.authorization] { resp.headerFields[.authorization] = auth }
            return (resp, nil)
        }
        XCTAssertNil(response.headerFields[.authorization])
    }
}

final class BackendURLStoreOverrideTests: XCTestCase {
    private func freshStore() -> BackendURLStore {
        BackendURLStore(userDefaults: UserDefaults(suiteName: "vesta.test.\(UUID().uuidString)")!)
    }

    func testOverrideLifecycle() {
        let store = freshStore()
        XCTAssertFalse(store.hasOverride())
        let url = BackendURLStore.canonicalize("https://my.example")!
        store.saveOverride(url)
        XCTAssertTrue(store.hasOverride())
        XCTAssertEqual(store.currentEffectiveURL(), url)
        store.clearOverride()
        XCTAssertFalse(store.hasOverride())
    }

    func testBundledDefaultAlwaysValid() {
        let store = freshStore()
        XCTAssertFalse(store.bundledBaseURL().absoluteString.isEmpty)
        // With no override, the effective URL is the bundled default.
        XCTAssertEqual(store.currentEffectiveURL(), store.bundledBaseURL())
    }

    func testCorruptOverrideIsIgnored() {
        let defaults = UserDefaults(suiteName: "vesta.test.\(UUID().uuidString)")!
        defaults.set("not a url", forKey: BackendURLStore.userDefaultsKey)
        let store = BackendURLStore(userDefaults: defaults)
        XCTAssertFalse(store.hasOverride())   // garbage cleared on load
    }
}
