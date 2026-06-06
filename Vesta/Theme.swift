import SwiftUI

/// Warm, minimal palette echoing hestia's web dashboard (cream surfaces, a
/// terracotta accent) — re-implemented natively, not copied.
enum Theme {
    static let background = Color("BackgroundBase")
    static let accent = Color.accentColor

    /// Warm card / row surface that sits above ``background``.
    static let surface = Color("Surface")

    static let textPrimary = Color(.label)
    static let textSecondary = Color(.secondaryLabel)

    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 14
}

extension View {
    /// Standard card chrome used by room/device tiles.
    func vestaCard() -> some View {
        self
            .padding(Theme.cardPadding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}
