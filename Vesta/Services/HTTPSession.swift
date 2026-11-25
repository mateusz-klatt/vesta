import Foundation

/// Cookie-free URL sessions for hestia.
///
/// hestia's `/api/login` always sets its httponly `hestia_session` cookie — even
/// for a native `bearer: true` login — and `URLSession.shared` would store it and
/// replay it next to our `Authorization` header. Vesta authenticates by bearer
/// only, so cookies are switched off entirely: nothing is stored, nothing is
/// sent, and hestia's "cookie and Authorization together" rejection can't trip.
/// Ephemeral also keeps responses (home state, receipts) out of the disk cache.
enum HTTPSession {
    static let shared = URLSession(configuration: configuration, delegate: HestiaRedirectDelegate(), delegateQueue: nil)
    // A feature probe stays on the public route and uses no HTTP credentials.
    static let featuresProbe = URLSession(
        configuration: featuresProbeConfiguration, delegate: FeaturesProbeDelegate(), delegateQueue: nil
    )

    static var featuresProbeConfiguration: URLSessionConfiguration {
        let probeConfiguration = configuration
        probeConfiguration.urlCredentialStorage = nil
        probeConfiguration.httpAdditionalHeaders = ["Cache-Control": "no-store"]
        return probeConfiguration
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }
}

private final class FeaturesProbeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge), nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (Self.disposition(for: challenge), nil)
    }

    private static func disposition(for challenge: URLAuthenticationChallenge) -> URLSession.AuthChallengeDisposition {
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .rejectProtectionSpace
    }
}

final class HestiaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let original = task.originalRequest?.url, let target = request.url,
              let scheme = original.scheme?.lowercased(), let host = original.host?.lowercased(),
              scheme == target.scheme?.lowercased(), host == target.host?.lowercased()
        else { return nil }

        let defaultPort = scheme == "https" ? 443 : 80
        guard (original.port ?? defaultPort) == (target.port ?? defaultPort) else { return nil }

        // Budget routes use a scoped device credential (or must never be reached by
        // redirecting a session-authenticated request below the bearer middleware).
        guard !Self.isBudgetPath(original),
              !Self.isBudgetPath(target),
              task.currentRequest?.url.map(Self.isBudgetPath) != true,
              response.url.map(Self.isBudgetPath) != true
        else { return nil }
        return request
    }

    private static func isBudgetPath(_ url: URL) -> Bool {
        guard let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath,
              let decoded = rawPath.removingPercentEncoding
        else { return true }

        // Reject encoded slashes before or after decoding, and any backslash.
        if rawPath.range(of: "%2f", options: .caseInsensitive) != nil
            || decoded.range(of: "%2f", options: .caseInsensitive) != nil
            || decoded.contains("\\") {
            return true
        }

        var segments: [Substring] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." {
                continue
            } else if segment == ".." {
                if !segments.isEmpty { segments.removeLast() }
            } else {
                segments.append(segment)
            }
        }
        let normalized = "/" + segments.joined(separator: "/").lowercased()
        return normalized == "/api/budget" || normalized.hasPrefix("/api/budget/")
    }
}
