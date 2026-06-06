import Foundation
import OSLog

/// Consumes hestia's `/api/events` SSE stream. Emits `.connected` once the stream
/// is live (HTTP 200) so the caller can refetch a fresh snapshot — SSE only carries
/// *future* events — then a `.change` per device-state frame. A single call covers
/// one connection; hestia closes the stream after its max lifetime (it expects
/// clients to reconnect, like a browser EventSource), so `AppState` loops over this.
enum EventStream {
    static let log = Logger(subsystem: "ie.klatt.vesta", category: "sse")

    enum Event: Sendable {
        case connected            // stream is live — caller should snapshot
        case change(node: Int?)   // a state frame (node id, or nil for activity/discovery)
    }

    private struct Frame: Decodable {
        let type: String?
        let node: Int?
    }

    static func changes() -> AsyncStream<Event> {
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
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        log.error("SSE bad status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
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
