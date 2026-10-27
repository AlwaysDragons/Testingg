import BackgroundTasks
import Foundation
import Observation

/// The AI daily briefing: one line on Home (tap for detail), refreshed once a day, and a local
/// notification at your briefing time. A background refresh tries to prepare it shortly before then.
/// (Remote push via APNs needs a paid developer account and a server key; local notifications cover this.)
@Observable
@MainActor
final class BriefingService {
    static let taskId = "com.forge.briefing"
    static let notificationId = "briefing.next"

    struct Result: Decodable { let line: String; let detail: String? }

    private(set) var today: BriefingCache.Entry? = BriefingCache.today()
    private(set) var isLoading = false

    /// Fetches today's briefing once per day (no-op if already cached).
    func refreshIfNeeded(_ client: SupabaseClient?, deviceContext: String? = nil, force: Bool = false) async {
        today = BriefingCache.today()
        guard let client, force || today == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let r = await Self.fetch(client, deviceContext: deviceContext) {
            BriefingCache.save(r.line, detail: r.detail)
            today = BriefingCache.today()
        }
    }

    nonisolated static func fetch(_ client: SupabaseClient, deviceContext: String?) async -> Result? {
        var params: [String: JSONValue] = [:]
        if let deviceContext { params["device_context"] = .string(deviceContext) }
        return try? await AgentClient(supabase: client).task("briefing", params: params, as: Result.self).result
    }

    /// Schedules the next briefing notification (and a background refresh shortly before it).
    static func schedule(settings: UserSettings?, now: Date = Date()) async {
        let scheduler = NotificationScheduler.shared
        guard let s = settings, s.notificationsEnabled, let time = s.briefingTime, let minutes = QuietHours.minutes(time) else {
            scheduler.cancel(ids: [notificationId])
            return
        }
        let cal = Calendar.current
        var fire = cal.startOfDay(for: now).addingTimeInterval(Double(minutes) * 60)
        if fire <= now { fire = cal.date(byAdding: .day, value: 1, to: fire) ?? fire }
        let cached = BriefingCache.today(now: fire)
        await scheduler.schedule(id: notificationId, title: "Your day", body: cached?.text ?? "Your briefing is ready.",
                                 at: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = fire.addingTimeInterval(-45 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Background app refresh: prepare today's briefing and put it in the notification.
    static func backgroundRefresh() async {
        let cloud = CloudSync()
        guard let client = cloud.supabase else { return }
        let repo = LifeRepository(client: client)
        let settings = try? await repo.settings()
        if BriefingCache.today() == nil, let r = await fetch(client, deviceContext: nil) {
            BriefingCache.save(r.line, detail: r.detail)
        }
        await schedule(settings: settings)
    }
}
