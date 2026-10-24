import Foundation

struct LiftPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let e1rm: Double
    let topSet: HevySet
}

struct LiftStat: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let group: MuscleGroup
    let points: [LiftPoint]          // oldest → newest, one per session
    let bestE1RM: Double
    let trendPct: Double?            // last 28d best vs prior 28d best
    let isStalled: Bool
    var lastDate: Date { points.last?.date ?? .distantPast }
}

struct MuscleVolume: Identifiable, Hashable {
    var id: MuscleGroup { group }
    let group: MuscleGroup
    let last7: Double
    let avg4w: Double
}

struct WeekPoint: Identifiable, Hashable {
    var id: Date { weekStart }
    let weekStart: Date
    let tonnageKg: Double
    let sets: Int
    let sessions: Int
}

struct PRRecord: Identifiable, Hashable {
    var id: String { title + "\(date.timeIntervalSince1970)" }
    let title: String
    let date: Date
    let e1rm: Double
    let previousBest: Double
}

struct Analysis {
    var lifts: [LiftStat] = []
    var volume: [MuscleVolume] = []
    var weeks: [WeekPoint] = []
    var recentPRs: [PRRecord] = []
    var workoutsThisWeek = 0
    var avgSessionsPerWeek = 0.0
    var avgDurationMin = 0.0
    var setsLast48h = 0
    var lastTrained: [TrainingCategory: Date] = [:]
    var totalWorkouts = 0
    var firstWorkout: Date?

    var stalled: [LiftStat] { lifts.filter(\.isStalled) }
    static let empty = Analysis()
}

/// Resolves which muscle groups an exercise hits.
struct MuscleResolver {
    var templates: [String: HevyExerciseTemplate]

    func primary(_ e: HevyExercise) -> MuscleGroup {
        if let id = e.exerciseTemplateId, let t = templates[id], let p = t.primaryMuscleGroup, let g = MuscleGroup(rawValue: p) {
            return g
        }
        return MuscleGroup.guess(fromTitle: e.title)
    }

    func secondary(_ e: HevyExercise) -> [MuscleGroup] {
        guard let id = e.exerciseTemplateId, let t = templates[id] else { return [] }
        return (t.secondaryMuscleGroups ?? []).compactMap { MuscleGroup(rawValue: $0) }
    }

    /// Dominant training category of a workout, by working sets.
    func category(of w: HevyWorkout) -> TrainingCategory {
        var counts: [TrainingCategory: Int] = [:]
        for e in w.exercises { counts[primary(e).category, default: 0] += e.workingSets.count }
        counts[.other] = nil
        counts[.core] = nil
        return counts.max { $0.value < $1.value }?.key ?? .other
    }
}

enum Analyzer {
    static func analyze(_ workouts: [HevyWorkout], resolver: MuscleResolver, now: Date = Date()) -> Analysis {
        guard !workouts.isEmpty else { return .empty }
        let cal = Calendar.current
        let sorted = workouts.sorted { $0.startTime < $1.startTime }
        var a = Analysis()
        a.totalWorkouts = sorted.count
        a.firstWorkout = sorted.first?.startTime

        // Lifts
        var byLift: [String: [LiftPoint]] = [:]
        var groupOf: [String: MuscleGroup] = [:]
        for w in sorted {
            for e in w.exercises {
                guard let top = e.topSet, let e1 = top.e1RM else { continue }
                byLift[e.title, default: []].append(LiftPoint(date: w.startTime, e1rm: e1, topSet: top))
                groupOf[e.title] = resolver.primary(e)
            }
        }
        let d28 = cal.date(byAdding: .day, value: -28, to: now)!
        let d56 = cal.date(byAdding: .day, value: -56, to: now)!
        let d14 = cal.date(byAdding: .day, value: -14, to: now)!

        a.lifts = byLift.map { title, pts in
            let recent = pts.filter { $0.date >= d28 }.map(\.e1rm).max()
            let prior = pts.filter { $0.date >= d56 && $0.date < d28 }.map(\.e1rm).max()
            var trend: Double?
            if let r = recent, let p = prior, p > 0 { trend = (r - p) / p * 100 }

            // Stalled: ≥4 sessions in 8 weeks, and the last 3 didn't beat the earlier best.
            var stalled = false
            let window = pts.filter { $0.date >= d56 }
            if window.count >= 4 {
                let last3 = window.suffix(3).map(\.e1rm).max() ?? 0
                let before = window.dropLast(3).map(\.e1rm).max() ?? 0
                stalled = last3 <= before * 1.005
            }
            return LiftStat(title: title, group: groupOf[title] ?? .other, points: pts,
                            bestE1RM: pts.map(\.e1rm).max() ?? 0, trendPct: trend, isStalled: stalled)
        }
        .sorted { $0.points.count > $1.points.count }

        // PRs in the last 14 days
        for lift in a.lifts {
            var best = 0.0
            for p in lift.points {
                if p.e1rm > best * 1.001 {
                    if best > 0, p.date >= d14 {
                        a.recentPRs.append(PRRecord(title: lift.title, date: p.date, e1rm: p.e1rm, previousBest: best))
                    }
                    best = p.e1rm
                }
            }
        }
        a.recentPRs.sort { $0.date > $1.date }

        // Volume per muscle (primary = 1 set, secondary = 0.5)
        let d7 = cal.date(byAdding: .day, value: -7, to: now)!
        var last7: [MuscleGroup: Double] = [:]
        var last28: [MuscleGroup: Double] = [:]
        for w in sorted where w.startTime >= d28 {
            for e in w.exercises {
                let n = Double(e.workingSets.count)
                let p = resolver.primary(e)
                last28[p, default: 0] += n
                if w.startTime >= d7 { last7[p, default: 0] += n }
                for s in resolver.secondary(e) {
                    last28[s, default: 0] += n * 0.5
                    if w.startTime >= d7 { last7[s, default: 0] += n * 0.5 }
                }
            }
        }
        a.volume = MuscleGroup.tracked.map { MuscleVolume(group: $0, last7: last7[$0] ?? 0, avg4w: (last28[$0] ?? 0) / 4) }

        // Weekly series (last 12 weeks)
        func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d) }
        let thisWeek = weekStart(now)
        var weeks: [Date: (Double, Int, Int)] = [:]
        for i in 0..<12 { weeks[cal.date(byAdding: .weekOfYear, value: -i, to: thisWeek)!] = (0, 0, 0) }
        for w in sorted {
            let k = weekStart(w.startTime)
            guard let cur = weeks[k] else { continue }
            weeks[k] = (cur.0 + w.tonnageKg, cur.1 + w.workingSetCount, cur.2 + 1)
        }
        a.weeks = weeks.map { WeekPoint(weekStart: $0.key, tonnageKg: $0.value.0, sets: $0.value.1, sessions: $0.value.2) }
            .sorted { $0.weekStart < $1.weekStart }
        a.workoutsThisWeek = weeks[thisWeek]?.2 ?? 0
        let last4 = sorted.filter { $0.startTime >= d28 }
        a.avgSessionsPerWeek = Double(last4.count) / 4
        a.avgDurationMin = last4.isEmpty ? 0 : last4.map(\.durationMinutes).reduce(0, +) / Double(last4.count)

        let h48 = now.addingTimeInterval(-48 * 3600)
        a.setsLast48h = sorted.filter { $0.startTime >= h48 }.reduce(0) { $0 + $1.workingSetCount }

        for w in sorted {
            for e in w.exercises where !e.workingSets.isEmpty {
                a.lastTrained[resolver.primary(e).category] = w.startTime
            }
        }
        return a
    }

    /// Weekdays (Calendar weekday 1=Sun…7=Sat) the user typically trains, inferred from the last 8 weeks.
    static func inferredTrainingDays(_ workouts: [HevyWorkout], now: Date = Date()) -> Set<Int> {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -56, to: now)!
        let recent = workouts.filter { $0.startTime >= cutoff }
        guard recent.count >= 4 else { return [2, 3, 5, 6] }
        var hits: [Int: Set<Int>] = [:]  // weekday -> set of week numbers
        for w in recent {
            let wd = cal.component(.weekday, from: w.startTime)
            let wk = cal.component(.weekOfYear, from: w.startTime)
            hits[wd, default: []].insert(wk)
        }
        let days = Set(hits.filter { Double($0.value.count) / 8 >= 0.4 }.keys)
        return days.isEmpty ? [2, 3, 5, 6] : days
    }

    /// Most likely training focus for a weekday, only if the user reliably trains the same thing that day.
    static func weekdayFocus(weekday: Int, workouts: [HevyWorkout], resolver: MuscleResolver, now: Date = Date()) -> TrainingCategory? {
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -56, to: now)!
        var counts: [TrainingCategory: Int] = [:]
        for w in workouts where w.startTime >= cutoff && cal.component(.weekday, from: w.startTime) == weekday {
            counts[resolver.category(of: w), default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total >= 3, let top = counts.max(by: { $0.value < $1.value }), Double(top.value) / Double(total) >= 0.7 else { return nil }
        return top.key
    }

    /// When each category was last trained (push/pull/legs), used to predict a rotating split.
    static func lastTrainedMain(_ workouts: [HevyWorkout], resolver: MuscleResolver, now: Date = Date()) -> [TrainingCategory: Date] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -21, to: now)!
        var out: [TrainingCategory: Date] = [:]
        for w in workouts where w.startTime >= cutoff {
            let c = resolver.category(of: w)
            guard [.push, .pull, .legs].contains(c) else { continue }
            if (out[c] ?? .distantPast) < w.startTime { out[c] = w.startTime }
        }
        return out
    }
}
