import ActivityKit
import Foundation
import Observation

struct HabitStreak: Decodable, Hashable, Sendable {
    var itemId: UUID
    var title: String
    var current: Int
    var longest: Int
    var doneToday: Bool
    var last7: Int
    var areaId: UUID?
}

/// Habit streaks (computed in Postgres by `ai_habit_streak`, the same rules the assistant sees).
@Observable
@MainActor
final class HabitsStore {
    private(set) var streaks: [UUID: HabitStreak] = [:]
    private var client: SupabaseClient?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { streaks = [:]; return }
        let list: [HabitStreak] = (try? await LifeRepository(client: client).rpc("ai_streaks")) ?? []
        streaks = Dictionary(list.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// One tap: done for today (idempotent on the server).
    func log(_ item: Item, store: LifeStore) async {
        guard let client else { return }
        if var s = streaks[item.id], !s.doneToday { s.doneToday = true; s.current += 1; streaks[item.id] = s }   // optimistic
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_log_habit", ["p_item_id": .of(item.id)])
        await store.reload(["logs"])
        await reload()
    }
}

/// Focus timer: a focus log on the server, a Live Activity and an end-of-session notification on the device.
@Observable
@MainActor
final class FocusStore {
    struct Session: Equatable {
        var logId: UUID
        var areaId: UUID
        var areaName: String
        var started: Date
        var minutes: Int
        var endsAt: Date { started.addingTimeInterval(Double(minutes) * 60) }
    }

    struct Total: Decodable, Hashable { var areaId: UUID; var area: String; var minutes: Int }

    private(set) var active: Session?
    private(set) var totals: [Total] = []
    var showSheet = false
    /// "What should I do now?" sheet.
    var showNextAction = false
    private var client: SupabaseClient?
    @ObservationIgnored private var activity: Activity<FocusActivityAttributes>?
    static let notificationId = "focus.end"

    func connect(_ client: SupabaseClient?, store: LifeStore) async {
        self.client = client
        await restore(store: store)
    }

    /// Picks up a session that's still running (e.g. after the app was closed).
    func restore(store: LifeStore) async {
        guard let client else { active = nil; return }
        let repo = LifeRepository(client: client)
        let open: [LogEntry] = (try? await repo.get("logs", ["select": "id,area_id,item_id,note,data,logged_at", "data->>focus": "eq.true",
                                                              "data->ended_at": "is.null", "order": "logged_at.desc", "limit": "1"])) ?? []
        if let log = open.first, let started = log.data["started_at"]?.string.flatMap(LifeCoding.parse) {
            let minutes = log.data["planned_minutes"]?.int ?? 25
            active = Session(logId: log.id, areaId: log.areaId, areaName: store.area(log.areaId)?.name ?? "Focus", started: started, minutes: minutes)
            if let a = active, a.endsAt < Date().addingTimeInterval(-Double(minutes) * 60) { await end() }   // long abandoned
        } else {
            active = nil
        }
        totals = (try? await repo.rpc("ai_focus_totals", ["p_days": .int(7)])) ?? []
    }

    func start(area: Area, minutes: Int, store: LifeStore) async {
        guard let client else { return }
        struct Started: Decodable { struct L: Decodable { var id: UUID }; var log: L }
        do {
            let r: Started = try await LifeRepository(client: client).rpc("ai_start_focus", ["p_area": .string(area.id.uuidString.lowercased()), "p_minutes": .int(minutes)])
            let session = Session(logId: r.log.id, areaId: area.id, areaName: area.name, started: Date(), minutes: minutes)
            active = session
            startActivity(session, accentHex: area.accentHex)
            let end = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: session.endsAt)
            await NotificationScheduler.shared.schedule(id: Self.notificationId, title: "Focus done", body: "\(minutes) minutes on \(area.name).", at: end, repeats: false)
            await store.reload(["logs"])
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    func end(store: LifeStore? = nil) async {
        guard let client else { return }
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_end_focus")
        active = nil
        NotificationScheduler.shared.cancel(ids: [Self.notificationId])
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
        }
        totals = (try? await LifeRepository(client: client).rpc("ai_focus_totals", ["p_days": .int(7)])) ?? []
        if let store { await store.reload(["logs"]) }
    }

    private func startActivity(_ s: Session, accentHex: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = FocusActivityAttributes(areaName: s.areaName, accentHex: accentHex, minutes: s.minutes)
        let state = FocusActivityAttributes.ContentState(endsAt: s.endsAt, paused: false)
        activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: s.endsAt.addingTimeInterval(60)))
    }
}

/// "What should I do now?"
struct NextAction: Decodable, Equatable, Sendable {
    struct Option: Decodable, Equatable, Sendable, Hashable { var title: String; var itemId: UUID?; var area: String?; var minutes: Int? }
    var action: Option
    var alternates: [Option]
    var why: String
}
