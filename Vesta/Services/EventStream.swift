import Foundation

/// Consumes hestia's `/api/events` Server-Sent-Events stream and yields a tick
/// whenever a state event arrives. OpenAPI has no streaming model, so this is
/// plain `URLSession.bytes` line parsing; the UI reacts by refetching discovery.
enum EventStream {
    static func ticks() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                let url = AppConfig.serverURL.appendingPathComponent("api/events")
                var request = URLRequest(url: url)
                request.setValue(AppConfig.ContentType.eventStream, forHTTPHeaderField: "Accept")
                if let token = TokenStore.load() {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                request.timeoutInterval = .infinity
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish()
                        return
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix("data:") { continuation.yield(()) }
                    }
                } catch {
                    // Stream ended or failed; caller may reconnect.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
