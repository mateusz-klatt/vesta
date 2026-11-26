import Foundation

/// App-wide configuration resolved at access time.
///
/// The backend origin layers as: ``BackendURLStore`` override → bundled
/// ``Configuration.plist`` default. Everything downstream (the generated API
/// client, the SSE stream) reads ``serverURL`` so a backend change is picked up
/// on the next evaluation without rebuilding shared services.
enum AppConfig {

    /// Active hestia origin (scheme + host [+ port]). Always valid.
    static var serverURL: URL { BackendURLStore.shared.currentEffectiveURL() }

    static let nativeBudgetEnabled = false
    static let receiptReviewEnabled = false

    static var nativeBudgetEnabledForBuild: Bool {
        #if DEBUG
        return nativeBudgetEnabled || ProcessInfo.processInfo.arguments.contains("-vesta.nativeBudget")
        #else
        return false
        #endif
    }

    static var receiptReviewEnabledForBuild: Bool {
        #if DEBUG
        return receiptReviewEnabled || ProcessInfo.processInfo.arguments.contains("-vesta.receiptReview")
        #else
        return false
        #endif
    }

    enum ContentType {
        static let json = "application/json"
        static let eventStream = "text/event-stream"
    }
}
