import SwiftUI

@main
struct ForgeApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            // Life dashboard is the root; the original RootView tabs open from the Gym area (LegacyForgeView).
            LifeRootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Today", systemImage: "bolt.heart.fill") }
            TrainingView().tabItem { Label("Training", systemImage: "dumbbell.fill") }
            RecoveryView().tabItem { Label("Recovery", systemImage: "drop.fill") }
            CoachView().tabItem { Label("Coach", systemImage: "sparkles") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task { if model.hasHevy { await model.refreshAll() } }
        .onChange(of: phase) { _, new in
            if new == .active, model.hasHevy { Task { await model.refreshAll() } }
        }
        .cloudSync()
    }
}
