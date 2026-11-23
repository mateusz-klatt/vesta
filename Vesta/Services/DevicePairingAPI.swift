import Foundation

struct ReceiptPairingCode: Equatable, Sendable {
    let value: String

    init?(_ input: String) {
        let code = input.filter { !$0.isWhitespace && $0 != "-" }
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz234567"
        guard code.count == 8, code.allSatisfy(alphabet.contains) else { return nil }
        value = code.uppercased()
    }

    init?(qrPayload: String) {
        let prefix = "hestia-pair:"
        guard qrPayload.hasPrefix(prefix) else { return nil }
        self.init(String(qrPayload.dropFirst(prefix.count)))
    }
}

/// The server enforces expiry. Preserve its wire value without assuming a date format.
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

/// Temporary HTTP client until these endpoints appear in the OpenAPI contract.
struct URLSessionDevicePairingAPI: DevicePairingAPI {
    var session: URLSession = HTTPSession.shared

    func redeem(code: ReceiptPairingCode, deviceName: String, server: URL) async throws -> ReceiptDeviceToken {
        struct Request: Encodable {
            let code: String
            let device_name: String
        }
        struct Response: Decodable {
            let token: String
            let token_id: String
            let scope: String
            let expires_at: DeviceTokenExpiry
        }

        let (data, status) = try await post("redeem", server: server, body: Request(code: code.value, device_name: deviceName))
        if status != 200 {
            let code = (try? JSONDecoder().decode(BudgetErrorEnvelope.self, from: data))?.code
            let error = ReceiptError.from(status: status, code: code)
            if error == .disabled || error == .ambiguousAuth { throw DevicePairingError.receipts(error) }
        }
        guard status == 200, let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.token.isEmpty, !response.token_id.isEmpty else {
            throw DevicePairingError.redeemFailed
        }
        return ReceiptDeviceToken(token: response.token, tokenID: response.token_id, expiresAt: response.expires_at)
    }

    func revoke(_ token: ReceiptDeviceToken, server: URL) async throws {
        struct Request: Encodable {
            let token_id: String
        }
        let (_, status) = try await post("revoke", server: server, body: Request(token_id: token.tokenID), bearer: token.token)
        guard (200..<300).contains(status) else { throw APIError.http(status) }
    }

    private func post(_ action: String, server: URL, body: some Encodable, bearer: String? = nil) async throws -> (Data, Int) {
        let url = server.appending(path: "/api/budget/receipts/device-token/\(action)")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue(AppConfig.ContentType.json, forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request, delegate: PairingRedirectDelegate())
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, response.statusCode)
    }
}

/// A redirect could replay a one-time code or token outside its configured origin.
private final class PairingRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
