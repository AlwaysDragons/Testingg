import Foundation

/// Turns everything the app knows into a compact, token-efficient brief for the AI coach.
enum CoachContext {
    static func systemPrompt(workouts: [HevyWorkout], health: HealthData, analysis: Analysis, readiness: Readiness?,
                             plan: [DayPlan], resolver: MuscleResolver, lbs: Bool, goals: String, now: Date = Date()) -> String {
        let unit = lbs ? "lb" : "kg"
        func w(_ kg: Double) -> String { String(format: "%.0f", Fmt.weightValue(kg, lbs: lbs)) }
        var s = """
        You are Forge, an elite strength & hypertrophy coach with sports-science and recovery expertise.
        The athlete trains at OneLife Fitness, which has a sauna, cold plunge, hot tub, HydroMassage beds and pneumatic compression leg sleeves.
        Their #1 goals: maximize muscle growth and overall health. Personal notes/goals: \(goals.isEmpty ? "none given" : goals)

        Rules:
        - Use their actual numbers. Be specific: exercises, sets, reps, loads in \(unit), RIR, durations, temperatures.
        - Hypertrophy principles: ~10–20 hard sets/muscle/week, 0–3 RIR, progressive overload, 1.6–2.2 g/kg protein, 7–9 h sleep.
        - Never schedule cold plunge within 6 h after lifting (blunts hypertrophy). Sauna post-lift is fine.
        - Flag injury/overtraining risk (falling HRV, rising RHR, short sleep, stalled lifts). Not medical advice; suggest a doctor for pain or abnormal vitals.
        - Format for a phone: short sections with **bold labels**, "- " bullets, no markdown headings (#), no tables. Be concise.

        Today is \(Fmt.iso.string(from: now)). Units: \(unit).

        """

        // Readiness
        if let r = readiness {
            s += "READINESS: \(r.score)/100 (\(r.label)). " + r.factors.map { "\($0.name) \($0.value) (\($0.detail))" }.joined(separator: "; ") + "\n\n"
        }

        // Health (last 30 days)
        s += "APPLE HEALTH (date: steps, sleep h, HRV ms, RHR, active kcal, kcal in, protein g):\n"
        let cal = Calendar.current
        for i in (0..<30).reversed() {
            guard let d = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: now)) else { continue }
            func v(_ arr: [DailyMetric], _ f: String = "%.0f") -> String { arr.value(on: d).map { String(format: f, $0) } ?? "-" }
            let row = [v(health.steps), v(health.sleepHours, "%.1f"), v(health.hrv), v(health.restingHr),
                       v(health.activeEnergy), v(health.caloriesIn), v(health.proteinG)]
            if row.allSatisfy({ $0 == "-" }) { continue }
            s += "\(Fmt.iso.string(from: d)): " + row.joined(separator: ", ") + "\n"
        }
        if let m = health.bodyMassKg.latest {
            let old = health.bodyMassKg.min { $0.date < $1.date }
            s += "Bodyweight: \(w(m.value)) \(unit)" + (old.map { " (was \(w($0.value)) on \(Fmt.iso.string(from: $0.date)))" } ?? "") + "\n"
        }
        if let f = health.bodyFatPct.latest { s += String(format: "Body fat: %.1f%%\n", f.value) }
        if let v = health.vo2Max.latest { s += String(format: "VO2 max: %.1f\n", v.value) }
        s += "\n"

        // Training analysis
        s += "TRAINING SUMMARY: \(analysis.totalWorkouts) workouts logged since \(analysis.firstWorkout.map { Fmt.iso.string(from: $0) } ?? "-"). "
        s += String(format: "%.1f sessions/week (last 4 wks), avg %.0f min. This week: %d.\n", analysis.avgSessionsPerWeek, analysis.avgDurationMin, analysis.workoutsThisWeek)
        s += "Hard sets per muscle (last 7d / weekly avg over 4 wks): "
        s += analysis.volume.map { "\($0.group.display) " + String(format: "%.0f/%.0f", $0.last7, $0.avg4w) }.joined(separator: ", ") + "\n"
        s += "Weekly tonnage (\(unit)): " + analysis.weeks.map { "\(Fmt.iso.string(from: $0.weekStart)) \(w($0.tonnageKg))" }.joined(separator: ", ") + "\n"
        s += "Lifts (best e1RM, 4-wk trend, stalled?):\n"
        for l in analysis.lifts.prefix(25) {
            let trend = l.trendPct.map { String(format: "%+.1f%%", $0) } ?? "n/a"
            s += "- \(l.title) [\(l.group.display)]: e1RM \(w(l.bestE1RM)), trend \(trend)\(l.isStalled ? ", STALLED" : ""), \(l.points.count) sessions\n"
        }
        if !analysis.recentPRs.isEmpty {
            s += "Recent PRs: " + analysis.recentPRs.prefix(8).map { "\($0.title) \(w($0.e1rm)) e1RM on \(Fmt.iso.string(from: $0.date))" }.joined(separator: "; ") + "\n"
        }
        s += "\n"

        // Full workout log (last 90 days)
        let cutoff = cal.date(byAdding: .day, value: -90, to: now)!
        s += "WORKOUT LOG (last 90 days, working sets as weight×reps):\n"
        for wk in workouts.filter({ $0.startTime >= cutoff }).sorted(by: { $0.startTime > $1.startTime }).prefix(70) {
            s += "\(Fmt.iso.string(from: wk.startTime)) \(wk.title) (\(Int(wk.durationMinutes)) min): "
            s += wk.exercises.map { e in
                "\(e.title) " + e.workingSets.map { Fmt.set($0, lbs: lbs) }.joined(separator: ",")
            }.joined(separator: " | ") + "\n"
        }
        s += "\n"

        // Recovery plan
        s += "PLANNED WEEK (training + OneLife recovery):\n"
        for d in plan {
            s += "\(Fmt.day.string(from: d.date)): \(d.headline). " + d.items.map { "\($0.modality.name) \($0.dose) (\($0.timing))" }.joined(separator: "; ") + "\n"
        }
        return s
    }

    static let quickPrompts: [(title: String, icon: String, prompt: String)] = [
        ("Full analysis", "sparkles", "Give me a full analysis of my training, recovery and health data. What's working, what isn't, and the 5 highest-impact changes I should make for muscle growth."),
        ("Plan my week", "calendar", "Build my next 7 days: each workout (exercises, sets × reps, target loads, RIR) plus exactly when to use the sauna, cold plunge, hot tub, HydroMassage and compression sleeves at OneLife."),
        ("Break plateaus", "chart.line.uptrend.xyaxis", "Which of my lifts are stalling and why? Give a specific plan to break each plateau over the next 4 weeks."),
        ("Today", "sun.max.fill", "Based on my readiness and recent training, what exactly should I do today — training and recovery?"),
        ("Volume check", "square.stack.3d.up.fill", "Am I doing the right amount of volume for each muscle group for hypertrophy? Which muscles are under- or over-trained?"),
        ("Nutrition & sleep", "moon.zzz.fill", "Review my sleep, protein, calories and bodyweight trend. Am I set up to build muscle? What should I change?")
    ]
}
