import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Attaches `Authorization: Bearer <token>` to every request when a token is
/// stored. hestia issues the token to native clients that log in with
/// `bearer: true`; the browser uses an httponly cookie instead.
struct BearerAuthMiddleware: ClientMiddleware {
    let token: @Sendable () -> String?

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID _: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if let token = token() {
            request.headerFields[.authorization] = "Bearer \(token)"
        }
        return try await next(request, body, baseURL)
    }
}
