import SwiftUI
import SwiftData

@main
struct AudioMagicianApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.lumen)
                .task { model.unlock.start() }
        }
        .modelContainer(for: [Room.self, TuningRecord.self])
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.hasOnboarded {
                HomeView()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: model.hasOnboarded)
    }
}
