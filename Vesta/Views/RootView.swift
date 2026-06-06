import SwiftUI

/// Top-level router: progress while probing, the connect/login surface when we
/// need a backend or credentials, the rooms home once we have state.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch app.phase {
            case .connecting:
                ProgressView("Connecting…")
                    .controlSize(.large)
            case .needsAuth, .failed:
                ConnectView()
            case .ready:
                HomeView()
            }
        }
        .task { await app.bootstrap() }
    }
}
