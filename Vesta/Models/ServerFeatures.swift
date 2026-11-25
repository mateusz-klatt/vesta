import Foundation

enum ServerFeature: String, Hashable, Codable, Sendable {
    case capabilities = "capabilities"
    case qrLogin = "qr_login"
    case deviceExchange = "device_exchange"
    case calendarInstances = "calendar_instances"
    case budgetNativeRead = "budget_native_read"
}

struct ServerFeatures: Equatable, Sendable {
    let authContract: Int
    let features: Set<ServerFeature>
    let qrOrigin: URL?
    let isLegacy: Bool

    static let legacy = ServerFeatures(authContract: 0, features: [], qrOrigin: nil, isLegacy: true)

    func supports(_ feature: ServerFeature) -> Bool { !isLegacy && features.contains(feature) }
}
