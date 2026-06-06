import SwiftUI

/// Top-level router: spinner while probing, the connect/onboarding/sign-in
/// surface when there's no session, the rooms home once we have state.
struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            switch app.phase {
            case .connecting:
                ProgressView("Connecting…")
                    .controlSize(.large)
            case .unconfigured, .needsAuth, .failed:
                ConnectView()
            case .ready:
                HomeView()
            }
        }
        .task { await app.bootstrap() }
    }
}
