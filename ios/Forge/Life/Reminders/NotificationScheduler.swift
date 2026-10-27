import Foundation
import UserNotifications

/// Local notifications for reminders with notify_mode "app" (plus other features' notifications).
/// Permission is asked in context, never on first launch. Actionable: Done, Snooze 10m / 1h / Tomorrow.
/// Rescheduled on launch and after every reminders change; quiet hours push alerts to the window's end.
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()
    private let center = UNUserNotificationCenter.current()
    weak var store: LifeStore?
    /// Lets other features handle taps on their own notifications (e.g. "checkin.morning").
    var tapHandlers: [String: @MainActor (String) -> Void] = [:]

    static let reminderCategory = "reminder"
    private static let prefix = "reminder."
    private static let maxPending = 50   // iOS keeps at most 64 pending

    func install() {
        center.delegate = self
        let actions = [
            UNNotificationAction(identifier: "done", title: "Done"),
            UNNotificationAction(identifier: "snooze10", title: "Snooze 10 min"),
            UNNotificationAction(identifier: "snooze60", title: "Snooze 1 hour"),
            UNNotificationAction(identifier: "tomorrow", title: "Tomorrow"),
        ]
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.reminderCategory, actions: actions, intentIdentifiers: [])])
    }

    /// Asks once, when the user first turns on notifications or creates an app-notified reminder.
    @discardableResult
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func isAuthorized() async -> Bool {
        let s = await center.notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    /// Replaces all pending reminder notifications with the current set.
    func reschedule(_ reminders: [Reminder], settings: UserSettings?, now: Date = Date()) async {
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard settings?.notificationsEnabled ?? false, await isAuthorized() else { return }

        let due = reminders
            .filter { $0.notifyMode == "app" && !$0.isDone && $0.syncStatus != "pending_delete" }
            .compactMap { r -> (Reminder, Date)? in
                guard let at = r.remindAt else { return nil }
                let fire = QuietHours.adjust(at, start: settings?.quietHoursStart, end: settings?.quietHoursEnd)
                return fire > now ? (r, fire) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.maxPending)

        for (r, fire) in due {
            let content = UNMutableNotificationContent()
            content.title = r.title
            if let notes = r.notes, !notes.isEmpty { content.body = notes }
            content.sound = .default
            content.categoryIdentifier = Self.reminderCategory
            content.threadIdentifier = "reminders"   // grouped
            content.userInfo = ["reminder_id": r.id.uuidString]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let request = UNNotificationRequest(identifier: Self.prefix + r.id.uuidString,
                                                content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(request)
        }
    }

    /// Schedules (or replaces) a simple local notification for other features (check-ins, briefing, nudges).
    func schedule(id: String, title: String, body: String?, at comps: DateComponents, repeats: Bool) async {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        content.threadIdentifier = id.components(separatedBy: ".").first ?? id
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: repeats)))
    }

    func cancel(ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["reminder_id"] as? String
        let requestId = response.notification.request.identifier
        let action = response.actionIdentifier
        await MainActor.run {
            if let id, let uuid = UUID(uuidString: id) {
                Task { await self.handle(action: action, reminder: uuid) }
            } else if let handler = self.tapHandlers.first(where: { requestId.hasPrefix($0.key) })?.value {
                handler(requestId)
            }
        }
    }

    private func handle(action: String, reminder id: UUID) async {
        guard let store, let r = store.reminders.first(where: { $0.id == id }) else { return }
        switch action {
        case "done": await store.completeReminder(r)
        case "snooze10": await store.snooze(r, until: Date().addingTimeInterval(10 * 60))
        case "snooze60": await store.snooze(r, until: Date().addingTimeInterval(3600))
        case "tomorrow":
            let base = r.remindAt ?? Date()
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: max(base, Date())) ?? Date()
            await store.snooze(r, until: tomorrow)
        default: break
        }
    }
}
