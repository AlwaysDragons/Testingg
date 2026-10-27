import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Shared between the app and the ForgeWidgets extension (both targets compile this file).

/// App Group used to hand the widget a snapshot. Must match the App Group capability on both targets.
enum AppGroup {
    static let id = "group.com.raoulreinder.forge"
    static var container: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
}

/// What the widgets show. The app writes it after every reload; widgets only read it.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct AreaTile: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var symbol: String
        var accentHex: String
        var value: String
        var label: String
        var progress: Double?
    }

    struct Habit: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var doneToday: Bool
    }

    var updated: Date
    var line: String
    var dueToday: Int
    var overdue: Int
    var remindersDue: Int
    var habitsLeft: Int
    var areas: [AreaTile]
    var habits: [Habit]
    var readiness: Int?

    static let placeholder = WidgetSnapshot(
        updated: Date(), line: "2 due today, 1 reminder.", dueToday: 2, overdue: 0, remindersDue: 1, habitsLeft: 1,
        areas: [AreaTile(id: "gym", name: "Gym", symbol: "dumbbell", accentHex: "#E86A5C", value: "3/4", label: "workouts", progress: 0.75),
                AreaTile(id: "sleep", name: "Sleep", symbol: "bed.double", accentHex: "#4FB3D9", value: "7.4h", label: "last night", progress: nil)],
        habits: [Habit(id: "h1", title: "Stretch", doneToday: true), Habit(id: "h2", title: "Read 20 min", doneToday: false)],
        readiness: 78)

    private static var url: URL? { AppGroup.container?.appendingPathComponent("widget-snapshot.json") }

    static func load() -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when the App Group isn't available (e.g. free signing without the capability).
    @discardableResult
    func save() -> Bool {
        guard let url = Self.url else { return false }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let data = try? e.encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}

#if canImport(ActivityKit) && os(iOS)
/// Live Activity for the focus timer (Phase 11 starts it; the widget extension renders it).
struct FocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endsAt: Date
        var paused: Bool
    }
    var areaName: String
    var accentHex: String
    var minutes: Int
}
#endif
