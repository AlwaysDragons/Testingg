import Foundation

/// A calendar event copied out of EventKit (device-only, never stored in Supabase).
struct CalEvent: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarTitle: String
    var colorHex: String?
}

/// One row of the unified Today timeline.
struct TimelineEntry: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case event(CalEvent), item(Item), reminder(Reminder) }
    var kind: Kind
    var time: Date?          // nil = all day / no time
    var end: Date?

    var id: String {
        switch kind {
        case .event(let e): return "e:" + e.id
        case .item(let i): return "i:" + i.id.uuidString
        case .reminder(let r): return "r:" + r.id.uuidString
        }
    }
}

/// Builds the Today timeline and finds free time. Pure, unit-tested.
enum Timeline {
    /// Events, items due today and reminders today, sorted by time; untimed entries first.
    static func build(events: [CalEvent], items: [Item], reminders: [Reminder], day: Date = Date(), calendar: Calendar = .current) -> [TimelineEntry] {
        let start = calendar.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        var out: [TimelineEntry] = []
        for e in events where e.end > start && e.start < end {
            out.append(TimelineEntry(kind: .event(e), time: e.isAllDay ? nil : e.start, end: e.isAllDay ? nil : e.end))
        }
        for i in items where !i.isDone && !i.isHabit {
            guard let due = i.dueDate, due >= start, due < end else { continue }
            out.append(TimelineEntry(kind: .item(i), time: hasTime(due, calendar) ? due : nil, end: nil))
        }
        for r in reminders where !r.isDone && r.syncStatus != "pending_delete" {
            guard let at = r.remindAt, at >= start, at < end else { continue }
            out.append(TimelineEntry(kind: .reminder(r), time: at, end: nil))
        }
        return out.sorted { a, b in
            switch (a.time, b.time) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x == y ? a.id < b.id : x < y
            }
        }
    }

    struct Slot: Equatable, Sendable { var start: Date; var end: Date; var minutes: Int { Int(end.timeIntervalSince(start) / 60) } }

    /// Gaps between timed events from `from` until `until`, at least `minMinutes` long.
    static func freeSlots(events: [CalEvent], from: Date, until: Date, minMinutes: Int = 15) -> [Slot] {
        let busy = events.filter { !$0.isAllDay && $0.end > from && $0.start < until }.sorted { $0.start < $1.start }
        var slots: [Slot] = []
        var cursor = from
        for e in busy {
            if e.start > cursor { slots.append(Slot(start: cursor, end: e.start)) }
            cursor = max(cursor, e.end)
        }
        if until > cursor { slots.append(Slot(start: cursor, end: until)) }
        return slots.filter { $0.minutes >= minMinutes }
    }

    /// A short plain-text summary for the assistant (calendar data stays on the device otherwise).
    static func context(events: [CalEvent], now: Date = Date(), calendar: Calendar = .current) -> String {
        let todays = events.filter { calendar.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }.sorted { $0.start < $1.start }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "HH:mm"
        let list = todays.prefix(12).map { $0.isAllDay ? "\($0.title) (all day)" : "\(f.string(from: $0.start))-\(f.string(from: $0.end)) \($0.title)" }
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86_400 - 3600)   // until 23:00
        let free = freeSlots(events: todays, from: now, until: endOfDay, minMinutes: 30).prefix(6)
            .map { "\(f.string(from: $0.start))-\(f.string(from: $0.end))" }
        var parts = ["Calendar today: " + (list.isEmpty ? "no events" : list.joined(separator: "; "))]
        if !free.isEmpty { parts.append("Free: " + free.joined(separator: ", ")) }
        return parts.joined(separator: ". ")
    }

    private static func hasTime(_ d: Date, _ calendar: Calendar) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0
    }
}
