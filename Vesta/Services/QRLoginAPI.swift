import Foundation

// QR redeem stays on the isolated transport. Its wire types match hestia 0.54.0 (0bf8940).
struct QRLoginRequest: Encodable {
    let origin: String
    let code: String
}

struct QRLoginResponse: Codable, Sendable {
    let ok: Bool
    let user: String
    let token: String
}

struct QRLoginErrorResponse: Decodable {
    struct Detail: Decodable {
        let code: String
    }

    let error: Detail
}

// A server can delay QR redemption for at most 15 minutes per response.
private let maximumQRRetryDelay: TimeInterval = 900

enum QRLoginError: LocalizedError, Equatable, Sendable {
    case unsupported
    case ambiguousAuth
    case originMismatch
    case invalidCode
    case rateLimited(retryAfter: TimeInterval?)
    case originUnavailable
    case failed

    var message: LocalizedStringResource { message(locale: .current) }
    var errorDescription: String? { String(localized: message) }

    func message(locale: Locale) -> LocalizedStringResource {
        switch self {
        case .unsupported: "This server doesn’t support QR sign-in."
        case .ambiguousAuth: "Hestia refused the sign-in request."
        case .originMismatch: "This code is for a different server."
        case .invalidCode: "This code is invalid or has expired. Scan a new one."
        case .rateLimited(let delay?) where delay > 0 && delay <= maximumQRRetryDelay:
            "Too many sign-in attempts. Try again in \(Self.localizedDelay(delay, locale: locale))."
        case .rateLimited: "Too many sign-in attempts. Try again later."
        case .originUnavailable: APIError.cannotConnect.message
        case .failed: APIError.unexpected("").message
        }
    }

    private static func localizedDelay(_ delay: TimeInterval, locale: Locale) -> String {
        Measurement(value: ceil(delay), unit: UnitDuration.seconds)
            .formatted(.measurement(width: .wide, usage: .asProvided).locale(locale))
    }
}

actor QRLoginAPI {
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private var retryDeadlines: [URL: ContinuousClock.Instant] = [:]

    init(session: URLSession = HTTPSession.qrRedeem,
         now: @escaping @Sendable () -> Date = { .now },
         monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.session = session
        self.now = now
        self.monotonicNow = monotonicNow
    }

    func redeem(origin: URL, code: String) async throws -> QRLoginResponse {
        try Task.checkCancellation()
        guard QRLoginPayload.canonicalOrigin(origin.absoluteString[...]) == origin else { throw QRLoginError.originMismatch }
        let requestedAt = monotonicNow()
        retryDeadlines = retryDeadlines.filter { $0.value > requestedAt }
        if let deadline = retryDeadlines[origin] {
            let remaining = requestedAt.duration(to: deadline).components
            let delay = TimeInterval(remaining.seconds) + TimeInterval(remaining.attoseconds) / 1e18
            throw QRLoginError.rateLimited(retryAfter: delay)
        }

        var request = URLRequest(url: origin.appending(path: "/api/auth/qr-redeem"))
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let data: Data
        let response: URLResponse
        do {
            request.httpBody = try JSONEncoder().encode(QRLoginRequest(origin: origin.absoluteString, code: code))
            (data, response) = try await session.data(for: request)
        } catch {
            // Encoder/transport errors may contain request data. Expose only fixed cases.
            if Task.isCancelled { throw CancellationError() }
            throw QRLoginError.failed
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw QRLoginError.failed }

        let decoder = JSONDecoder()
        if http.statusCode == 200 {
            guard let result = try? decoder.decode(QRLoginResponse.self, from: data) else { throw QRLoginError.failed }
            return result
        }

        let errorCode = (try? decoder.decode(QRLoginErrorResponse.self, from: data))?.error.code
        switch (http.statusCode, errorCode) {
        case (400, "qr_auth_ambiguous"): throw QRLoginError.ambiguousAuth
        case (400, "qr_origin_mismatch"): throw QRLoginError.originMismatch
        case (400, "qr_invalid_request"), (408, _), (411, _), (413, _), (415, _):
            throw QRLoginError.failed
        case (401, "qr_code_invalid"): throw QRLoginError.invalidCode
        case (429, _):
            let receivedAt = monotonicNow()
            let delay = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: now())
            if let delay, delay > 0 {
                let deadline = receivedAt.advanced(by: .seconds(delay))
                retryDeadlines[origin] = max(retryDeadlines[origin] ?? receivedAt, deadline)
            }
            throw QRLoginError.rateLimited(retryAfter: delay)
        case (503, _): throw QRLoginError.originUnavailable
        default: throw QRLoginError.failed
        }
    }

    private static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
            return min(TimeInterval(UInt64(value) ?? .max), maximumQRRetryDelay)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        // HTTP-date uses IMF-fixdate and accepts the two historical formats.
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
            "EEE MMM dd HH:mm:ss yyyy",
            "EEE MMM  d HH:mm:ss yyyy",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        for format in formats {
            formatter.dateFormat = format
            // Reject normalized invalid dates and inputs that only parse partially.
            if let date = formatter.date(from: value), formatter.string(from: date) == value {
                return min(max(0, date.timeIntervalSince(now)), maximumQRRetryDelay)
            }
        }
        return nil
    }
}
