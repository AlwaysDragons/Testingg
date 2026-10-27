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
    @State private var captures = CaptureStore()
    @State private var everyday = EverydayStore()
    @State private var calendar = CalendarService()
    @State private var habits = HabitsStore()
    @State private var focus = FocusStore()

    var body: some View {
        LifeTabs()
            .environment(store)
            .environment(chat)
            .environment(reminderSync)
            .environment(briefing)
            .environment(captures)
            .environment(everyday)
            .environment(calendar)
            .environment(habits)
            .environment(focus)
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
    @Environment(AppModel.self) private var model
    @Environment(CaptureStore.self) private var captures
    @Environment(EverydayStore.self) private var everyday
    @Environment(CalendarService.self) private var calendar
    @Environment(HabitsStore.self) private var habits
    @Environment(FocusStore.self) private var focus
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var chat = chat
        @Bindable var captures = captures
        @Bindable var everyday = everyday
        @Bindable var focus = focus
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
            await captures.connect(cloud.supabase)
            await everyday.connect(cloud.supabase)
            await habits.connect(cloud.supabase)
            await focus.connect(cloud.supabase, store: store)
            await Self.scheduleEveryday(store)
            await Self.remindersChanged(store, reminderSync)
            await briefing.refreshIfNeeded(cloud.supabase, deviceContext: deviceContext)
            await BriefingService.schedule(settings: store.settings)
        }
        .onChange(of: phase) { _, new in
            if new == .active {
                Task {
                    await Self.remindersChanged(store, reminderSync)
                    await briefing.refreshIfNeeded(cloud.supabase, deviceContext: deviceContext)
                }
            }
            if new == .background { Task { await BriefingService.schedule(settings: store.settings) } }
        }
        .sheet(isPresented: $chat.isPresented) { ChatSheet().environment(chat).environment(store) }
        .sheet(isPresented: $captures.isPresented) { CaptureSheet().environment(captures).environment(store) }
        .sheet(isPresented: $everyday.showCheckin) { CheckinSheet().environment(everyday) }
        .sheet(isPresented: $focus.showSheet) { FocusSheet().environment(focus).environment(store) }
        .sheet(isPresented: $focus.showNextAction) {
            NextActionSheet().environment(focus).environment(store).environment(calendar).environment(cloud)
        }
        .sheet(isPresented: $everyday.showReview) {
            NavigationStack { WeeklyReviewView() }.environment(everyday).environment(store)
        }
        // forge://capture (widgets, Action Button), forge://home
        .onOpenURL { url in
            guard url.scheme == "forge" else { return }
            if url.host == "capture" { captures.open() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(IntentEvents.Event.openCapture.rawValue))) { _ in
            IntentEvents.pendingCapture = false
            captures.open()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(IntentEvents.Event.dashboardChanged.rawValue))) { _ in
            Task { await store.reloadAll() }
        }
        .onAppear {
            if IntentEvents.pendingCapture { IntentEvents.pendingCapture = false; captures.open() }
            let store = store, reminderSync = reminderSync, chat = chat, model = model, briefing = briefing, everyday = everyday, habits = habits, focus = focus
            NotificationScheduler.shared.tapHandlers = [
                "checkin.": { _ in everyday.showCheckin = true },
                "review.": { _ in everyday.showReview = true },
                "focus.": { _ in focus.showSheet = true },
            ]
            // Widgets read a snapshot the app writes after every reload.
            store.onReloaded = [{ WidgetBridge.update(store: store, model: model, briefing: briefing.today?.text) }]
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
                WidgetBridge.update(store: store, model: model, briefing: briefing.today?.text)
                if tables.contains("ai_messages") { Task { await chat.reload() } }
                if tables.contains("captures") { Task { await captures.reload() } }
                if tables.contains("reminders") || tables.contains("user_settings") { Task { await Self.remindersChanged(store, reminderSync) } }
                if tables.contains("user_settings") {
                    Task {
                        await BriefingService.schedule(settings: store.settings)
                        await Self.scheduleEveryday(store)
                    }
                }
                if tables.contains("checkins") || tables.contains("journal_entries") { Task { await everyday.reload() } }
                if tables.contains("logs") || tables.contains("items") { Task { await habits.reload() } }
            }]
        }
    }
}

extension LifeTabs {
    /// Calendar summary for the assistant, only when Calendar is on (events otherwise stay on the device).
    var deviceContext: String? {
        store.isEnabled(.calendar) && calendar.authorized ? Timeline.context(events: calendar.today) : nil
    }

    @MainActor
    static func scheduleEveryday(_ store: LifeStore) async {
        await EverydayStore.scheduleNotifications(settings: store.settings, checkins: store.isEnabled(.checkins), review: store.isEnabled(.weeklyReview))
    }

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
