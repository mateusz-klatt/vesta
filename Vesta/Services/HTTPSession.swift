import Foundation

/// The one URLSession Vesta talks to hestia through (REST + SSE).
///
/// hestia's `/api/login` always sets its httponly `hestia_session` cookie — even
/// for a native `bearer: true` login — and `URLSession.shared` would store it and
/// replay it next to our `Authorization` header. Vesta authenticates by bearer
/// only, so cookies are switched off entirely: nothing is stored, nothing is
/// sent, and hestia's "cookie and Authorization together" rejection can't trip.
/// Ephemeral also keeps responses (home state, receipts) out of the disk cache.
enum HTTPSession {
    static let shared = URLSession(configuration: configuration)

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return configuration
    }
}
