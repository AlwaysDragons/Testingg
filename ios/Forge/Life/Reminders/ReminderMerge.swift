import Foundation

/// A copy of an Apple Reminders item (EventKit objects aren't Sendable, so the sync works on these).
struct AppleReminder: Equatable, Sendable {
    var id: String              // calendarItemIdentifier
    var listId: String          // calendar identifier
    var title: String
    var notes: String?
    var due: Date?
    var isCompleted: Bool
    var completedAt: Date?
    var lastModified: Date?
    var hasAlarm: Bool
}

/// Two-way sync plan between `reminders` rows and Apple Reminders. Pure, unit-tested.
/// Rule: the most recent modification wins; deletions on either side propagate; nothing is duplicated
/// (rows are matched on `apple_reminder_id`).
enum ReminderMerge {
    enum Action: Equatable, Sendable {
        case createApple(Reminder)                    // new in the app → add to Apple Reminders
        case updateApple(Reminder, appleId: String)   // app side is newer
        case deleteApple(appleId: String, rowId: UUID)
        case updateRow(UUID, from: AppleReminder)     // Apple side is newer
        case importApple(AppleReminder)               // new in Apple Reminders → add a row
        case deleteRow(UUID)                          // deleted in Apple Reminders (or pending delete with nothing to delete)
        case markSynced(UUID, modified: Date?)
    }

    /// - Parameters:
    ///   - rows: reminder rows loaded from Supabase.
    ///   - apple: Apple reminders from the synced lists, plus any linked to a row (looked up by id).
    ///   - now: for the 7-day import window of completed reminders.
    static func plan(rows: [Reminder], apple: [AppleReminder], now: Date = Date()) -> [Action] {
        var actions: [Action] = []
        let byId = Dictionary(apple.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var linked = Set<String>()

        for row in rows {
            guard let appleId = row.appleReminderId else {
                if row.syncStatus == "pending_delete" { actions.append(.deleteRow(row.id)) }
                else if row.syncStatus == "pending_push", !row.isDone { actions.append(.createApple(row)) }
                continue
            }
            linked.insert(appleId)
            guard let ek = byId[appleId] else {
                // Gone from Apple Reminders.
                if row.syncStatus == "pending_push", !row.isDone { actions.append(.createApple(row)) }
                else { actions.append(.deleteRow(row.id)) }
                continue
            }
            if row.syncStatus == "pending_delete" {
                actions.append(.deleteApple(appleId: appleId, rowId: row.id))
                continue
            }
            if sameContent(row, ek) {
                if row.syncStatus != "synced" { actions.append(.markSynced(row.id, modified: ek.lastModified)) }
                continue
            }
            let rowTime = row.sourceModifiedAt ?? row.updatedAt
            let ekTime = ek.lastModified ?? .distantPast
            if row.syncStatus == "pending_push" && rowTime >= ekTime.addingTimeInterval(-1) {
                actions.append(.updateApple(row, appleId: appleId))
            } else if ekTime > rowTime {
                actions.append(.updateRow(row.id, from: ek))
            } else {
                actions.append(.updateApple(row, appleId: appleId))
            }
        }

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        for ek in apple where !linked.contains(ek.id) {
            if !ek.isCompleted || (ek.completedAt ?? .distantPast) >= weekAgo { actions.append(.importApple(ek)) }
        }
        return actions
    }

    /// Same title, notes, due time (to the minute) and completion.
    static func sameContent(_ row: Reminder, _ ek: AppleReminder) -> Bool {
        row.title == ek.title &&
            (row.notes ?? "") == (ek.notes ?? "") &&
            minute(row.remindAt) == minute(ek.due) &&
            row.isDone == ek.isCompleted
    }

    private static func minute(_ d: Date?) -> Int? { d.map { Int(($0.timeIntervalSince1970 / 60).rounded(.down)) } }
}

/// Quiet hours: notifications that would fire inside the window move to its end.
enum QuietHours {
    /// `start`/`end` are Postgres time strings ("22:00:00"). Handles windows that cross midnight.
    static func adjust(_ date: Date, start: String?, end: String?, calendar: Calendar = .current) -> Date {
        guard let s = minutes(start), let e = minutes(end), s != e else { return date }
        let dayStart = calendar.startOfDay(for: date)
        let m = Int(date.timeIntervalSince(dayStart) / 60)
        let inside = s < e ? (m >= s && m < e) : (m >= s || m < e)
        guard inside else { return date }
        // End of the window: today if we're before it, otherwise tomorrow.
        let endToday = dayStart.addingTimeInterval(Double(e) * 60)
        return m < e ? endToday : calendar.date(byAdding: .day, value: 1, to: endToday) ?? endToday
    }

    static func contains(_ date: Date, start: String?, end: String?, calendar: Calendar = .current) -> Bool {
        adjust(date, start: start, end: end, calendar: calendar) != date
    }

    /// "22:30:00" → 1350
    static func minutes(_ t: String?) -> Int? {
        guard let t else { return nil }
        let parts = t.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// The subset of RFC 5545 RRULE the app uses: FREQ + INTERVAL (+ BYDAY kept as text).
struct SimpleRRule: Equatable, Sendable {
    enum Freq: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    var freq: Freq
    var interval: Int = 1

    init(freq: Freq, interval: Int = 1) {
        self.freq = freq
        self.interval = interval
    }

    init?(_ rule: String?) {
        guard let rule, !rule.isEmpty else { return nil }
        var parts: [String: String] = [:]
        for p in rule.uppercased().replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[String(kv[0])] = String(kv[1]) }
        }
        guard let f = parts["FREQ"].flatMap(Freq.init(rawValue:)) else { return nil }
        freq = f
        interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
    }

    var string: String { interval == 1 ? "FREQ=\(freq.rawValue)" : "FREQ=\(freq.rawValue);INTERVAL=\(interval)" }

    var label: String {
        let unit: String
        switch freq { case .daily: unit = "day"; case .weekly: unit = "week"; case .monthly: unit = "month"; case .yearly: unit = "year" }
        return interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
    }
}
