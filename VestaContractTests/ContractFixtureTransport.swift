import Foundation
import HTTPTypes
import OpenAPIRuntime
import XCTest

func contractClient(
    _ responses: [String: String],
    validate: @escaping @Sendable (HTTPRequest, HTTPBody?) async throws -> Void = { _, _ in }
) -> Client {
    Client(serverURL: URL(string: "https://hestia.example")!,
           transport: ContractFixtureTransport(responses: responses, validate: validate))
}

private struct ContractFixtureTransport: ClientTransport {
    let responses: [String: String]
    let validate: @Sendable (HTTPRequest, HTTPBody?) async throws -> Void

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL,
              operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let path = try XCTUnwrap(request.path)
        let key = "\(request.method) \(path)"
        let fixture = try XCTUnwrap(responses[key], "Unexpected legacy request \(key)")
        try await validate(request, body)
        return (HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]), HTTPBody(fixture))
    }
}
