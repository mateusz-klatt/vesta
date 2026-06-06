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
    ///
    /// `.id(language)` re-mounts the view tree on a language change so UIKit-bridged
    /// strings (e.g. the navigation title) re-resolve too. AppState lives on the App
    /// struct, so session/token/cache survive the re-mount and bootstrap is a no-op.
    @ViewBuilder private var content: some View {
        if let language = app.appLanguage {
            RootView()
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, Lang.isRTL(language) ? .rightToLeft : .leftToRight)
                .id(language)
        } else {
            RootView().id("system")
        }
    }
}
