import SwiftUI

@main
struct VestaApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            content
                .environment(app)
                .tint(Theme.accent)
        }
    }

    /// Apply the in-app language override (instant for SwiftUI text) and mirror the
    /// layout for right-to-left languages. nil = follow the system.
    @ViewBuilder private var content: some View {
        if let language = app.appLanguage {
            RootView()
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, Lang.isRTL(language) ? .rightToLeft : .leftToRight)
        } else {
            RootView()
        }
    }
}
