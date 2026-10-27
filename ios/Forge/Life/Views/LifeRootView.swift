import SwiftUI

/// The app's root: the life dashboard. Three tabs max (Home, Today, Settings).
/// The existing Forge screens live inside the Gym area (see `LegacyForgeView`).
struct LifeRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var store = LifeStore()
    @State private var chat = ChatStore()
    @State private var reminderSync = ReminderSync()
    @State private var briefing = BriefingService()

    var body: some View {
        LifeTabs()
            .environment(store)
            .environment(chat)
            .environment(reminderSync)
            .environment(briefing)
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
    @Environment(ChatStore.self) private var chat
    @Environment(ReminderSync.self) private var reminderSync
    @Environment(BriefingService.self) private var briefing
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var chat = chat
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "square.grid.2x2") }
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }
            LifeSettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(DS.Palette.primary)
        // Connect (or disconnect) the dashboard whenever sign-in changes.
        .task(id: cloud.isSignedIn) {
            await store.connect(cloud.supabase)
            await chat.connect(cloud.supabase)
            await Self.remindersChanged(store, reminderSync)
            await briefing.refreshIfNeeded(cloud.supabase)
            await BriefingService.schedule(settings: store.settings)
        }
        .onChange(of: phase) { _, new in
            if new == .active {
                Task {
                    await Self.remindersChanged(store, reminderSync)
                    await briefing.refreshIfNeeded(cloud.supabase)
                }
            }
            if new == .background { Task { await BriefingService.schedule(settings: store.settings) } }
        }
        .sheet(isPresented: $chat.isPresented) { ChatSheet().environment(chat).environment(store) }
        .onAppear {
            let store = store, reminderSync = reminderSync, chat = chat
            NotificationScheduler.shared.install()
            NotificationScheduler.shared.store = store
            reminderSync.store = store
            // The agent's changes arrive by realtime; also refresh right after a reply and push
            // any new reminders to Apple Reminders (EventKit writes happen on-device only).
            chat.onDeviceActions = [{ actions in
                await store.reloadAll()
                if !actions.isEmpty { await Self.remindersChanged(store, reminderSync) }
            }]
            store.onTableChange = [{ tables in
                if tables.contains("ai_messages") { Task { await chat.reload() } }
                if tables.contains("reminders") || tables.contains("user_settings") { Task { await Self.remindersChanged(store, reminderSync) } }
                if tables.contains("user_settings") { Task { await BriefingService.schedule(settings: store.settings) } }
            }]
        }
    }
}

extension LifeTabs {
    /// Sync Apple Reminders and reschedule local notifications.
    @MainActor
    static func remindersChanged(_ store: LifeStore, _ reminderSync: ReminderSync) async {
        guard store.isConnected else { return }
        await reminderSync.sync()
        await NotificationScheduler.shared.reschedule(store.reminders, settings: store.settings)
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
