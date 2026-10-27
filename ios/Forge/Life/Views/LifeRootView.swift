import SwiftUI

/// The app's root: the life dashboard. Three tabs max (Home, Today, Settings).
/// The existing Forge screens live inside the Gym area (see `LegacyForgeView`).
struct LifeRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var store = LifeStore()

    var body: some View {
        LifeTabs()
            .environment(store)
            // Same launch / foreground refresh the existing RootView does.
            .task { if model.hasHevy { await model.refreshAll() } }
            .onChange(of: phase) { _, new in
                if new == .active, model.hasHevy { Task { await model.refreshAll() } }
            }
            .cloudSync()
    }
}

private struct LifeTabs: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(LifeStore.self) private var store

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "square.grid.2x2") }
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }
            LifeSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(DS.Palette.primary)
        // Connect (or disconnect) the dashboard whenever sign-in changes.
        .task(id: cloud.isSignedIn) { await store.connect(cloud.supabase) }
    }
}

/// The original five Forge tabs, unchanged, opened from the Gym area. Swipe down to close.
struct LegacyForgeView: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud

    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Today", systemImage: "bolt.heart.fill") }
            TrainingView().tabItem { Label("Training", systemImage: "dumbbell.fill") }
            RecoveryView().tabItem { Label("Recovery", systemImage: "drop.fill") }
            CoachView().tabItem { Label("Coach", systemImage: "sparkles") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environment(model)
        .environment(cloud)
        .tint(Theme.accent)
        .environment(\.colorScheme, .dark)   // the existing screens are designed for dark mode
    }
}
