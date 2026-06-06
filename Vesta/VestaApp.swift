import SwiftUI

@main
struct VestaApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .tint(Theme.accent)
                // In-app language override (instant for SwiftUI text); nil = system.
                .environment(\.locale, Locale(identifier: app.appLanguage ?? Locale.current.identifier))
        }
    }
}
