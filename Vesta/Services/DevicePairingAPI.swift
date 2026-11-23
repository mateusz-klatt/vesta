import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

struct ReceiptPairingCode: Equatable, Sendable {
    let value: String

    /// hestia issues 8 characters of Crockford base32 (`0-9`, `A-Z` without
    /// I, L, O, U). Normalised exactly as hestia does: uppercase, spaces and
    /// dashes dropped, O → 0, I/L → 1; U is rejected.
    init?(_ input: String) {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let code = String(input.uppercased().compactMap { character -> Character? in
            if character.isWhitespace || character == "-" { return nil }
            switch character {
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        })
        guard code.count == 8, code.allSatisfy(alphabet.contains) else { return nil }
        value = code
    }

    init?(qrPayload: String) {
        let prefix = "hestia-pair:"
        guard qrPayload.hasPrefix(prefix) else { return nil }
        self.init(String(qrPayload.dropFirst(prefix.count)))
    }
}

/// Keep reading both expiry representations written by earlier Vesta builds.
enum DeviceTokenExpiry: Codable, Equatable, Sendable {
    case number(Double)
    case string(String)

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try value.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        }
    }
}

struct ReceiptDeviceToken: Codable, Equatable, Sendable {
    let token: String
    let tokenID: String
    let expiresAt: DeviceTokenExpiry
}

protocol DevicePairingAPI: Sendable {
    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken
    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws
}

enum DevicePairingError: Error {
    case redeemFailed
    case storage
    case receipts(ReceiptError)

    var message: LocalizedStringResource {
        switch self {
        case .redeemFailed: "Couldn’t pair this iPhone. Check the code or get a new one from hestia and try again."
        case .storage: "Couldn’t update pairing on this iPhone. Try again while it’s unlocked."
        case .receipts(let error): error.message
        }
    }
}

struct GeneratedDevicePairingAPI: DevicePairingAPI {
    private static let session: URLSession = {
        let configuration = HTTPSession.configuration
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: PairingRedirectDelegate(), delegateQueue: nil)
    }()

    private let transport: URLSessionTransport

    init(session: URLSession = Self.session) {
        transport = URLSessionTransport(configuration: .init(session: session, httpBodyProcessingMode: .buffered))
    }

    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        let client = makeClient(server: server)
        do {
            let result = try await client.redeemBudgetReceiptDevice(
                .init(body: .json(.init(code: code.value, deviceName: deviceName)))
            ).ok.body.json
            guard !result.token.isEmpty, !result.tokenId.isEmpty else { throw DevicePairingError.redeemFailed }
            let expiry = result.expiresAt.ISO8601Format(.init(includingFractionalSeconds: true))
            return ReceiptDeviceToken(token: result.token, tokenID: result.tokenId,
                                      expiresAt: .string(expiry))
        } catch {
            let error = ReceiptError.wrap(error)
            if error == .disabled || error == .ambiguousAuth { throw DevicePairingError.receipts(error) }
            throw DevicePairingError.redeemFailed
        }
    }

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        let client = makeClient(server: server, revoking: token)
        _ = try await client.revokeBudgetReceiptDevice(.init(body: .json(.init(tokenId: token.tokenID)))).ok
    }

    private func makeClient(server: URL, revoking token: ReceiptDeviceToken? = nil) -> Client {
        Client(serverURL: server, configuration: .init(dateTranscoder: PairingDateTranscoder()), transport: transport,
               middlewares: [BearerAuthMiddleware(token: { nil }, revoking: token)])
    }
}

/// Hestia's ISO 8601 timestamp may include fractional seconds.
private struct PairingDateTranscoder: DateTranscoder {
    private let fractional = ISO8601DateTranscoder.iso8601WithFractionalSeconds
    private let wholeSeconds = ISO8601DateTranscoder.iso8601

    func encode(_ date: Date) throws -> String { try fractional.encode(date) }

    func decode(_ value: String) throws -> Date {
        if let date = try? fractional.decode(value) { return date }
        return try wholeSeconds.decode(value)
    }
}

/// A redirect could replay a one-time code or token outside its configured origin.
private final class PairingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
