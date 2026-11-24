import Foundation
import OSLog

/// Consumes hestia's `/api/events` SSE stream. Emits `.connected` once the stream
/// is live (HTTP 200), then a `.change` per device-state frame. A single call covers
/// one connection; hestia closes the stream after its max lifetime (it expects
/// clients to reconnect, like a browser EventSource), so `AppState` loops over this.
enum EventStream {
    static let log = Logger(subsystem: "ie.klatt.vesta", category: "sse")

    enum Event: Equatable, Sendable {
        case connected            // stream is live — reset reconnect backoff
        case change(node: Int?)   // a state frame (node id, or nil for activity/discovery)
        case unauthorized
        case forbidden
    }

    private struct Frame: Decodable {
        let type: String?
        let node: Int?
    }

    static func changes(session: URLSession = HTTPSession.shared) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let url = AppConfig.serverURL.appendingPathComponent("api/events")
                var request = URLRequest(url: url)
                request.setValue(AppConfig.ContentType.eventStream, forHTTPHeaderField: "Accept")
                if let token = TokenStore.load() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                log.debug("SSE connecting \(url.absoluteString, privacy: .public)")
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode
                    guard status == 200 else {
                        if status == 401 { continuation.yield(.unauthorized) }
                        if status == 403 { continuation.yield(.forbidden) }
                        log.error("SSE bad status \(status ?? -1)")
                        continuation.finish()
                        return
                    }
                    log.notice("SSE connected")
                    continuation.yield(.connected)
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }   // skip :keepalive comments
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let frame = try? JSONDecoder().decode(Frame.self, from: Data(json.utf8))
                        log.debug("SSE frame \(json, privacy: .public)")
                        continuation.yield(.change(node: frame?.type == "state" ? frame?.node : nil))
                    }
                } catch {
                    log.error("SSE error: \(error.localizedDescription, privacy: .public)")
                }
                log.notice("SSE finished")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
