import Foundation
import Observation

struct Checkin: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var type: String            // morning | evening
    var mood: Int?
    var energy: Int?
    var wins: String?
    var notes: String?
    var date: String            // yyyy-MM-dd
}

struct JournalEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var date: String
    var content: String
    var source: String          // ai | manual
}

struct WeeklyReview: Codable, Equatable, Sendable {
    struct Suggestion: Codable, Equatable, Sendable, Hashable { var area: String; var title: String }
    var summary: String
    var wins: [String]
    var misses: [String]
    var focus: String
    var suggestions: [Suggestion]
}

/// Check-ins, weekly review and the daily journal.
@Observable
@MainActor
final class EverydayStore {
    private(set) var checkins: [Checkin] = []
    private(set) var journal: [JournalEntry] = []
    private(set) var review: WeeklyReview?
    private(set) var isGenerating = false
    var showCheckin = false
    var showReview = false
    var lastError: String?
    private var client: SupabaseClient?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { checkins = []; journal = []; return }
        let repo = LifeRepository(client: client)
        let since = LifeCoding.dayString(Date().addingTimeInterval(-60 * 86_400))
        checkins = (try? await repo.get("checkins", ["select": "id,type,mood,energy,wins,notes,date", "date": "gte.\(since)", "order": "date.desc"])) ?? []
        journal = (try? await repo.get("journal_entries", ["select": "id,date,content,source", "order": "date.desc", "limit": "90"])) ?? []
        review = Self.cachedReview()
    }

    // MARK: Check-ins

    /// Morning before 15:00, evening after.
    static func currentType(now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.component(.hour, from: now) < 15 ? "morning" : "evening"
    }

    func checkin(type: String, on day: Date = Date()) -> Checkin? {
        let d = LifeCoding.dayString(day)
        return checkins.first { $0.date == d && $0.type == type }
    }

    func submitCheckin(type: String, mood: Int?, energy: Int?, wins: String?, notes: String?) async {
        guard let client else { return }
        var p: [String: JSONValue] = ["type": .string(type), "date": .string(LifeCoding.dayString(Date()))]
        if let mood { p["mood"] = .int(mood) }
        if let energy { p["energy"] = .int(energy) }
        if let wins, !wins.isEmpty { p["wins"] = .string(wins) }
        if let notes, !notes.isEmpty { p["notes"] = .string(notes) }
        do {
            let _: JSONValue = try await LifeRepository(client: client).rpc("ai_submit_checkin", ["p": .object(p)])
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await reload()
    }

    // MARK: Weekly review (cached per week)

    static func weekStart(_ date: Date = Date()) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: date)?.start ?? cal.startOfDay(for: date)
    }

    private static let reviewKey = "life.weeklyReview"

    private static func cachedReview() -> WeeklyReview? {
        guard let d = UserDefaults.standard.dictionary(forKey: reviewKey), d["week"] as? String == LifeCoding.dayString(weekStart()),
              let data = d["json"] as? Data else { return nil }
        return try? JSONDecoder().decode(WeeklyReview.self, from: data)
    }

    func generateReview() async {
        guard let client, !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        let week = LifeCoding.dayString(Self.weekStart())
        do {
            let r = try await AgentClient(supabase: client).task("weekly_review", params: ["week_start": .string(week)], as: WeeklyReview.self).result
            review = r
            if let data = try? JSONEncoder().encode(r) { UserDefaults.standard.set(["week": week, "json": data], forKey: Self.reviewKey) }
            lastError = nil
        } catch { lastError = ChatStore.friendly(error) }
    }

    // MARK: Journal

    func entry(for day: Date) -> JournalEntry? { journal.first { $0.date == LifeCoding.dayString(day) } }

    func generateJournal(for day: Date) async {
        guard let client, !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        struct R: Decodable { let content: String; let saved: Bool }
        do {
            _ = try await AgentClient(supabase: client).task("journal", params: ["date": .string(LifeCoding.dayString(day))], as: R.self)
            lastError = nil
        } catch { lastError = ChatStore.friendly(error) }
        await reload()
    }

    /// Your own edit: saved as source "manual", so the AI never overwrites it.
    func saveJournal(_ content: String, for day: Date) async {
        guard let client else { return }
        let row: Row = ["date": .string(LifeCoding.dayString(day)), "content": .string(content), "source": .string("manual")]
        try? await client.rest("POST", "journal_entries", query: [.init(name: "on_conflict", value: "user_id,date")],
                               body: try JSONEncoder().encode([row]), prefer: "resolution=merge-duplicates,return=minimal")
        await reload()
    }

    /// Writes yesterday's journal once, if the feature is on and it's missing.
    func backfillYesterday() async {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()), entry(for: yesterday) == nil else { return }
        await generateJournal(for: yesterday)
    }

    // MARK: Notifications

    /// Daily check-in reminders and the Sunday review, when enabled.
    static func scheduleNotifications(settings: UserSettings?, checkins: Bool, review: Bool) async {
        let n = NotificationScheduler.shared
        let on = settings?.notificationsEnabled ?? false
        for (id, time, title) in [("checkin.morning", settings?.checkinMorningTime, "Morning check-in"),
                                  ("checkin.evening", settings?.checkinEveningTime, "Evening check-in")] {
            if on, checkins, let m = QuietHours.minutes(time) {
                await n.schedule(id: id, title: title, body: "Two taps: mood and energy.", at: DateComponents(hour: m / 60, minute: m % 60), repeats: true)
            } else {
                n.cancel(ids: [id])
            }
        }
        if on, review {
            await n.schedule(id: "review.weekly", title: "Weekly review", body: "See how your week went.",
                             at: DateComponents(hour: 18, minute: 0, weekday: 1), repeats: true)
        } else {
            n.cancel(ids: ["review.weekly"])
        }
    }
}
