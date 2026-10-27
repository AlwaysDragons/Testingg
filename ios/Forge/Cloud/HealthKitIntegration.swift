import Foundation

/// Adapter: pushes the daily Apple Health values already read by the existing `HealthKitManager`
/// into the generic `metrics` table (area "Health"). It does not query HealthKit itself.
struct HealthKitIntegration: Integration {
    let provider = "healthkit"
    let displayName = "Apple Health"
    /// Snapshot of `AppModel.health` (existing cache).
    let health: HealthData

    /// (metric name, unit, series). Names are stable: the AI and charts query by them.
    private var series: [(String, String, [DailyMetric])] {
        [
            ("steps", "count", health.steps),
            ("active_energy", "kcal", health.activeEnergy),
            ("resting_hr", "bpm", health.restingHr),
            ("hrv", "ms", health.hrv),
            ("sleep_hours", "h", health.sleepHours),
            ("bodyweight", "kg", health.bodyMassKg),
            ("body_fat", "%", health.bodyFatPct),
            ("vo2_max", "ml/kg/min", health.vo2Max),
            ("protein", "g", health.proteinG),
            ("calories_in", "kcal", health.caloriesIn)
        ]
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func sync(repo: CloudRepository, cursor: Date?) async throws -> SyncResult {
        guard !health.isEmpty else { return SyncResult(pushed: 0, cursor: cursor, summary: "No Health data yet") }
        // Re-push the last 3 days on every sync: today's totals (steps, sleep) keep changing.
        let since = cursor.flatMap { Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: $0)) }

        var rows = metricRows(since: since)
        guard !rows.isEmpty else { return SyncResult(pushed: 0, cursor: cursor, summary: "Up to date") }

        let area = try await repo.ensureArea(name: "Health", kind: "custom", icon: "heart")
        for i in rows.indices { rows[i]["area_id"] = .of(area) }
        try await repo.upsertMetrics(rows)
        return SyncResult(pushed: rows.count, cursor: health.lastUpdated ?? Date(), summary: "\(rows.count) daily values")
    }

    /// One row per metric per day, keyed by a stable external id like "hrv:2026-10-27".
    func metricRows(since: Date?) -> [Row] {
        var rows: [Row] = []
        for (name, unit, values) in series {
            for m in values where since.map({ m.date >= $0 }) ?? true {
                rows.append([
                    "name": .string(name),
                    "value": .number(m.value),
                    "unit": .string(unit),
                    "recorded_at": .of(m.date),
                    "source": .string("healthkit"),
                    "external_id": .string("\(name):\(Self.day.string(from: m.date))")
                ])
            }
        }
        return rows
    }
}
