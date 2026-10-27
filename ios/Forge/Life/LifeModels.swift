import Foundation

// Rows of the life-dashboard tables (snake_case JSON from PostgREST, decoded with `LifeCoding.decoder`).

struct Area: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var icon: String?
    var color: String?
    var kind: String
    var config: JSONValue
    var sortOrder: Int
    var pinned: Bool
    var hidden: Bool
    var createdAt: Date
    var updatedAt: Date

    var symbol: String { icon?.isEmpty == false ? icon! : AreaPalette.defaultSymbol(forKind: kind) }
    var accentHex: String { RGB(hex: color) != nil ? color! : AreaPalette.defaultHex(forKind: kind) }
}

struct Item: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var areaId: UUID
    var parentId: UUID?
    var title: String
    var status: String          // not_started | in_progress | done | blocked
    var progress: Int
    var priority: Int           // 0 none ... 3 high
    var dueDate: Date?
    var recurrence: String?
    var tags: [String]
    var data: JSONValue
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    var isDone: Bool { status == "done" }
    var isHabit: Bool { recurrence?.isEmpty == false }
}

struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var areaId: UUID
    var itemId: UUID?
    var note: String?
    var data: JSONValue
    var loggedAt: Date
}

struct Metric: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var areaId: UUID
    var name: String
    var value: Double
    var unit: String?
    var recordedAt: Date
    var data: JSONValue
    var source: String
}

struct Reminder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var itemId: UUID?
    var areaId: UUID?
    var title: String
    var notes: String?
    var remindAt: Date?
    var repeatRule: String?
    var notifyMode: String      // app | reminders_app | none
    var appleReminderId: String?
    var syncStatus: String      // synced | pending_push | pending_delete | conflict | error
    var completedAt: Date?
    var sourceModifiedAt: Date?
    var updatedAt: Date

    var isDone: Bool { completedAt != nil }
}

struct UserSettings: Codable, Hashable, Sendable {
    var userId: UUID
    var defaultNotifyMode: String
    var notificationsEnabled: Bool
    var quietHoursStart: String?   // "22:00:00"
    var quietHoursEnd: String?
    var briefingTime: String?
    var timezone: String
    var features: JSONValue
    var checkinMorningTime: String? = nil
    var checkinEveningTime: String? = nil
}

/// Features beyond the core start hidden; each one is switched on in Settings (stored in `user_settings.features`).
enum Feature: String, CaseIterable, Identifiable, Sendable {
    case capture, checkins, weeklyReview = "weekly_review", journal, calendar, habits, focus, nextAction = "next_action"
    case goals, nutrition, measurements, money, insights, nudges, people, lists, documents, travel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: return "Quick capture"
        case .checkins: return "Morning and evening check-in"
        case .weeklyReview: return "Weekly review"
        case .journal: return "Daily journal"
        case .calendar: return "Calendar"
        case .habits: return "Habit streaks"
        case .focus: return "Focus timer"
        case .nextAction: return "What should I do now?"
        case .goals: return "Goals with milestones"
        case .nutrition: return "Water, meals and supplements"
        case .measurements: return "Body measurements and photos"
        case .money: return "Money"
        case .insights: return "Insights"
        case .nudges: return "Nudges"
        case .people: return "People"
        case .lists: return "Shopping lists"
        case .documents: return "Documents"
        case .travel: return "Travel and packing"
        }
    }
}
