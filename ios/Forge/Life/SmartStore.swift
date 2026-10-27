import Foundation
import Observation

struct Insight: Decodable, Identifiable, Hashable, Sendable {
    var id: UUID
    var text: String
    var kind: String
    var sampleSize: Int?
}

struct Nudge: Decodable, Hashable, Sendable { var kind: String; var text: String }

struct SearchResult: Decodable, Identifiable, Hashable, Sendable {
    var type: String
    var id: UUID
    var title: String?
    var snippet: String?
    var date: String?
    var rowId: String { "\(type):\(id.uuidString):\(title ?? "")" }
}

/// Insights (computed in Postgres with sample sizes), gentle nudges, and search across everything.
@Observable
@MainActor
final class SmartStore {
    private(set) var insights: [Insight] = []
    private(set) var results: [SearchResult] = []
    private(set) var isSearching = false
    private var client: SupabaseClient?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { insights = []; return }
        insights = (try? await LifeRepository(client: client).rpc("ai_get_insights")) ?? []
    }

    /// Recomputes insights at most once a day.
    func refreshIfNeeded(force: Bool = false) async {
        guard let client else { return }
        let key = "smart.insightsDay", today = LifeCoding.dayString(Date())
        guard force || UserDefaults.standard.string(forKey: key) != today else { return }
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_compute_insights")
        UserDefaults.standard.set(today, forKey: key)
        await reload()
    }

    func dismiss(_ insight: Insight) async {
        insights.removeAll { $0.id == insight.id }
        guard let client else { return }
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_dismiss_insight", ["p_id": .of(insight.id)])
    }

    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, q.count >= 2 else { results = []; return }
        isSearching = true
        defer { isSearching = false }
        results = (try? await LifeRepository(client: client).rpc("ai_search_all", ["p_query": .string(q), "p_limit": .int(50)])) ?? []
    }

    // MARK: Nudges

    /// At most one nudge notification per day, at 18:00 (moved out of quiet hours), only when enabled.
    func scheduleNudge(settings: UserSettings?, enabled: Bool, now: Date = Date()) async {
        let id = "nudge.daily"
        guard enabled, settings?.notificationsEnabled == true, let client else { NotificationScheduler.shared.cancel(ids: [id]); return }
        let today = LifeCoding.dayString(now)
        guard UserDefaults.standard.string(forKey: "smart.nudgeDay") != today else { return }
        let nudges: [Nudge] = (try? await LifeRepository(client: client).rpc("ai_nudges")) ?? []
        guard let n = Self.pick(nudges, lastKind: UserDefaults.standard.string(forKey: "smart.nudgeKind")) else { return }
        var fire = Calendar.current.startOfDay(for: now).addingTimeInterval(18 * 3600)
        if fire <= now { fire = now.addingTimeInterval(15 * 60) }
        fire = QuietHours.adjust(fire, start: settings?.quietHoursStart, end: settings?.quietHoursEnd)
        await NotificationScheduler.shared.schedule(id: id, title: "A gentle nudge", body: n.text,
                                                   at: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire), repeats: false)
        UserDefaults.standard.set(today, forKey: "smart.nudgeDay")
        UserDefaults.standard.set(n.kind, forKey: "smart.nudgeKind")
    }

    /// Prefers a different kind than yesterday's so nudges don't repeat.
    nonisolated static func pick(_ nudges: [Nudge], lastKind: String?) -> Nudge? {
        nudges.first { $0.kind != lastKind } ?? nudges.first
    }
}
