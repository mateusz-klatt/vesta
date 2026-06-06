import Foundation

/// Consumes hestia's `/api/events` SSE stream. Each frame yields the node id of a
/// device state change (or nil for globals/klima/discovery frames) so the UI can
/// briefly highlight what just changed and refetch.
enum EventStream {
    private struct Frame: Decodable {
        let type: String?
        let node: Int?
    }

    static func changes() -> AsyncStream<Int?> {
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
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        let frame = try? JSONDecoder().decode(Frame.self, from: Data(json.utf8))
                        continuation.yield(frame?.type == "state" ? frame?.node : nil)
                    }
                } catch {
                    // stream ended or failed; caller may reconnect
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
