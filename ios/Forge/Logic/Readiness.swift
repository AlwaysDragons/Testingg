import Foundation

struct ReadinessFactor: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let value: String
    let detail: String
    let score: Int
}

struct Readiness {
    let score: Int
    let factors: [ReadinessFactor]

    var label: String {
        switch score {
        case 80...: return "Primed"
        case 65..<80: return "Ready"
        case 50..<65: return "Moderate"
        default: return "Recover"
        }
    }

    var advice: String {
        switch score {
        case 80...: return "Green light. Push intensity and chase PRs today."
        case 65..<80: return "Train as planned. Keep 1–2 reps in reserve on top sets."
        case 50..<65: return "Train, but trim volume ~20% and skip grinders."
        default: return "Prioritize recovery: deload or active recovery + contrast therapy."
        }
    }

    static func compute(health: HealthData, analysis: Analysis, now: Date = Date()) -> Readiness? {
        var factors: [ReadinessFactor] = []
        func clamp(_ v: Double) -> Int { Int(max(0, min(100, v)).rounded()) }

        if let today = health.hrv.latest, let base = health.hrv.average(lastDays: 30, excludingLatest: true, now: now), base > 0 {
            let ratio = today.value / base
            let pct = (ratio - 1) * 100
            factors.append(.init(name: "HRV", value: "\(Int(today.value)) ms",
                                 detail: String(format: "%+.0f%% vs 30-day avg", pct), score: clamp(60 + pct * 1.6)))
        }
        if let today = health.restingHr.latest, let base = health.restingHr.average(lastDays: 30, excludingLatest: true, now: now), base > 0 {
            let pct = (today.value / base - 1) * 100
            factors.append(.init(name: "Resting HR", value: "\(Int(today.value)) bpm",
                                 detail: String(format: "%+.0f%% vs 30-day avg", pct), score: clamp(65 - pct * 3.5)))
        }
        if let night = health.sleepHours.latest {
            let h = night.value
            factors.append(.init(name: "Sleep", value: String(format: "%.1f h", h),
                                 detail: h >= 7.5 ? "On target" : String(format: "%.1f h short of 7.5", 7.5 - h),
                                 score: clamp((h - 5) / 3 * 100)))
        }
        if analysis.totalWorkouts > 0 {
            let s = analysis.setsLast48h
            factors.append(.init(name: "Training load", value: "\(s) sets / 48h",
                                 detail: s > 35 ? "High recent load" : s > 15 ? "Moderate load" : "Fresh",
                                 score: clamp(100 - Double(s) * 1.6)))
        }
        guard !factors.isEmpty else { return nil }
        let weights: [String: Double] = ["HRV": 0.35, "Resting HR": 0.2, "Sleep": 0.3, "Training load": 0.15]
        let total = factors.reduce(0.0) { $0 + (weights[$1.name] ?? 0) }
        let score = factors.reduce(0.0) { $0 + Double($1.score) * (weights[$1.name] ?? 0) } / total
        return Readiness(score: Int(score.rounded()), factors: factors)
    }
}
