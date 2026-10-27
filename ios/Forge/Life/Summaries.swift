import Foundation

/// Glance-layer numbers, computed locally from loaded rows. Pure functions, unit-tested on Linux.
enum Summaries {
    enum Status: Equatable, Sendable { case none, good, behind, overdue }

    /// The one hero stat an area card shows.
    struct Hero: Equatable, Sendable {
        var value: String
        var label: String
        var secondary: String?
        var progress: Double?      // ring, 0...1
        var trend: [Double] = []   // sparkline
        var status: Status = .none
    }

    struct Today: Equatable, Sendable {
        var dueToday = 0
        var overdue = 0
        var remindersDue = 0
        var habitsLeft = 0
        var isClear: Bool { dueToday + overdue + remindersDue + habitsLeft == 0 }
    }

    /// Inputs for one area (pre-filtered by the store).
    struct AreaData: Sendable {
        var area: Area
        var items: [Item] = []
        var logs: [LogEntry] = []
        var metrics: [Metric] = []
        /// Gym only: workouts this week and the weekly target (from the existing Hevy analysis).
        var workoutsThisWeek: Int?
        var weeklyTarget: Int?
        /// Gym only: today's readiness (0-100) for "skip or push today?".
        var readiness: Int?
    }

    // MARK: Hero stat

    static func hero(_ d: AreaData, now: Date = Date(), calendar: Calendar = .current) -> Hero {
        let config = d.area.config
        // An explicit metric to feature, e.g. {"hero_metric": "sleep_hours"}.
        if let name = config["hero_metric"]?.string, let h = metricHero(name, d.metrics) { return h }

        switch d.area.kind {
        case "gym":
            let done = d.workoutsThisWeek ?? 0
            let target = max(1, config["weekly_target"]?.int ?? d.weeklyTarget ?? 3)
            let behind = done < expectedByNow(target: target, now: now, calendar: calendar)
            let verdict = SkipOrPush.verdict(d.readiness)
            // One caption line: "workouts this week", or "this week · push today" when readiness is known.
            return Hero(value: "\(done)/\(target)", label: verdict.map { "this week · \($0.label.lowercased().replacingOccurrences(of: " today", with: ""))" } ?? "workouts this week",
                        progress: Double(done) / Double(target),
                        status: done >= target ? .good : behind ? .behind : .none)
        case "habits":
            let habits = d.items.filter { $0.isHabit && !$0.isDone }
            if !habits.isEmpty {
                let doneToday = habits.filter { isLoggedToday($0, d.logs, now: now, calendar: calendar) }.count
                return Hero(value: "\(doneToday)/\(habits.count)", label: "habits today", progress: Double(doneToday) / Double(habits.count),
                            status: doneToday == habits.count ? .good : .none)
            }
        case "goals":
            let goals = d.items.filter { $0.parentId == nil && !$0.isDone }
            if !goals.isEmpty {
                let avg = goals.map(\.progress).reduce(0, +) / goals.count
                return Hero(value: "\(avg)%", label: goals.count == 1 ? goals[0].title : "average across \(goals.count) goals",
                            progress: Double(avg) / 100)
            }
        case "finance":
            let spent = monthTotal("expense", d.metrics, now: now, calendar: calendar)
            if spent > 0 || d.metrics.contains(where: { $0.name == "expense" }) {
                let currency = config["currency"]?.string ?? "USD"
                let budget = config["monthly_budget"]?.double
                return Hero(value: money(spent, currency), label: "spent this month",
                            secondary: budget.map { "of \(money($0, currency))" },
                            progress: budget.map { spent / max($0, 1) },
                            status: budget.map { spent > $0 ? .overdue : .none } ?? .none)
            }
        default:
            break
        }

        let open = d.items.filter { !$0.isDone }
        if !open.isEmpty {
            let overdue = open.filter { isOverdue($0, now: now, calendar: calendar) }.count
            return Hero(value: "\(open.count)", label: open.count == 1 ? "open item" : "open items",
                        secondary: overdue > 0 ? "\(overdue) overdue" : nil, status: overdue > 0 ? .overdue : .none)
        }
        if let latest = d.metrics.max(by: { $0.recordedAt < $1.recordedAt }), let h = metricHero(latest.name, d.metrics) { return h }
        if let last = d.logs.max(by: { $0.loggedAt < $1.loggedAt }) {
            return Hero(value: "\(d.logs.filter { $0.loggedAt > now.addingTimeInterval(-7 * 86_400) }.count)", label: "logs this week",
                        secondary: "last \(relative(last.loggedAt, now: now))")
        }
        return Hero(value: "–", label: "nothing yet")
    }

    /// Latest value of a metric with a 14-point trend.
    static func metricHero(_ name: String, _ metrics: [Metric]) -> Hero? {
        let series = metrics.filter { $0.name == name }.sorted { $0.recordedAt < $1.recordedAt }
        guard let last = series.last else { return nil }
        return Hero(value: number(last.value) + (last.unit.map { unitSuffix($0) } ?? ""), label: label(forMetric: name),
                    trend: series.suffix(14).map(\.value))
    }

    // MARK: Today strip

    static func today(items: [Item], reminders: [Reminder], logs: [LogEntry], now: Date = Date(), calendar: Calendar = .current) -> Today {
        var t = Today()
        for item in items where !item.isDone {
            if item.isHabit {
                if !isLoggedToday(item, logs, now: now, calendar: calendar) { t.habitsLeft += 1 }
            } else if isOverdue(item, now: now, calendar: calendar) {
                t.overdue += 1
            } else if let due = item.dueDate, calendar.isDate(due, inSameDayAs: now) {
                t.dueToday += 1
            }
        }
        t.remindersDue = reminders.filter { r in
            guard !r.isDone, r.syncStatus != "pending_delete", let at = r.remindAt else { return false }
            return at < calendar.startOfDay(for: now).addingTimeInterval(86_400)
        }.count
        return t
    }

    /// One calm sentence for the briefing line when no AI briefing is available.
    static func line(_ t: Today) -> String {
        if t.isClear { return "Nothing due today." }
        var parts: [String] = []
        if t.dueToday > 0 { parts.append("\(t.dueToday) due today") }
        if t.overdue > 0 { parts.append("\(t.overdue) overdue") }
        if t.remindersDue > 0 { parts.append(t.remindersDue == 1 ? "1 reminder" : "\(t.remindersDue) reminders") }
        if t.habitsLeft > 0 { parts.append(t.habitsLeft == 1 ? "1 habit left" : "\(t.habitsLeft) habits left") }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
    }

    // MARK: Item grouping (Area detail → Items)

    enum DueGroup: String, CaseIterable, Sendable {
        case overdue = "Overdue", today = "Today", tomorrow = "Tomorrow", week = "This week", later = "Later", none = "No date", done = "Done"
    }

    static func group(_ items: [Item], now: Date = Date(), calendar: Calendar = .current) -> [(DueGroup, [Item])] {
        let startToday = calendar.startOfDay(for: now)
        let startTomorrow = startToday.addingTimeInterval(86_400)
        let startDayAfter = startTomorrow.addingTimeInterval(86_400)
        let weekEnd = startToday.addingTimeInterval(7 * 86_400)
        var buckets: [DueGroup: [Item]] = [:]
        for item in items {
            let g: DueGroup
            if item.isDone { g = .done }
            else if let due = item.dueDate {
                if isOverdue(item, now: now, calendar: calendar) { g = .overdue }
                else if due < startTomorrow { g = .today }
                else if due < startDayAfter { g = .tomorrow }
                else if due < weekEnd { g = .week }
                else { g = .later }
            } else { g = .none }
            buckets[g, default: []].append(item)
        }
        return DueGroup.allCases.compactMap { g in
            guard var list = buckets[g], !list.isEmpty else { return nil }
            list.sort { a, b in
                if g == .done { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
                if a.priority != b.priority { return a.priority > b.priority }
                return (a.dueDate ?? .distantFuture) < (b.dueDate ?? .distantFuture)
            }
            return (g, list)
        }
    }

    // MARK: Helpers

    /// Overdue = due before today, or due earlier today at a specific time that has passed.
    static func isOverdue(_ item: Item, now: Date, calendar: Calendar) -> Bool {
        guard !item.isDone, let due = item.dueDate else { return false }
        if due < calendar.startOfDay(for: now) { return true }
        let comps = calendar.dateComponents([.hour, .minute], from: due)
        let hasTime = (comps.hour ?? 0) != 0 || (comps.minute ?? 0) != 0
        return hasTime && due < now && calendar.isDate(due, inSameDayAs: now)
    }

    static func isLoggedToday(_ item: Item, _ logs: [LogEntry], now: Date, calendar: Calendar) -> Bool {
        logs.contains { $0.itemId == item.id && calendar.isDate($0.loggedAt, inSameDayAs: now) }
    }

    /// Workouts you'd expect by now for an even spread over a Monday-start week.
    static func expectedByNow(target: Int, now: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: now)   // 1 = Sunday
        let dayIndex = (weekday + 5) % 7                          // Monday = 0 ... Sunday = 6
        return Int((Double(target) * Double(dayIndex) / 7).rounded(.down))
    }

    static func monthTotal(_ name: String, _ metrics: [Metric], now: Date, calendar: Calendar) -> Double {
        metrics.filter { $0.name == name && calendar.isDate($0.recordedAt, equalTo: now, toGranularity: .month) }.map(\.value).reduce(0, +)
    }

    static func number(_ v: Double) -> String {
        if v.rounded() == v && abs(v) < 1e9 { return String(Int(v)) }
        return String(format: abs(v) >= 100 ? "%.0f" : "%.1f", v)
    }

    static func unitSuffix(_ unit: String) -> String {
        ["%", "h", "kg", "lb", "k"].contains(unit) ? unit : " " + unit
    }

    static func money(_ v: Double, _ currency: String) -> String {
        let symbols = ["USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥"]
        let s = symbols[currency.uppercased()] ?? currency.uppercased() + " "
        return s + (v >= 1000 ? String(format: "%.0f", v) : number((v * 100).rounded() / 100))
    }

    /// "sleep_hours" → "sleep hours"
    static func label(forMetric name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(date) / 86_400)
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }

    static func greeting(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}
