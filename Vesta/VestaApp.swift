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

    /// `.id(language)` re-mounts the view tree on a language change so UIKit-bridged
    /// strings (e.g. the navigation title) re-resolve too. AppState lives on the App
    /// struct, so session/token/cache survive the re-mount and bootstrap is a no-op.
    private var content: some View {
        RootView()
            .appLanguage(app.appLanguage)
            .id(app.appLanguage ?? "system")
    }
}

extension View {
    /// Apply the in-app language override (locale + RTL layout). nil = follow the
    /// system. Reused on the root and on presented sheets so they mirror too.
    @ViewBuilder func appLanguage(_ language: String?) -> some View {
        if let language {
            self
                .environment(\.locale, Locale(identifier: language))
                .environment(\.layoutDirection, Lang.isRTL(language) ? .rightToLeft : .leftToRight)
        } else {
            self
        }
    }
}
