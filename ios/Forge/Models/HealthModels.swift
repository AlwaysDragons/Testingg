import Foundation

struct DailyMetric: Codable, Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

/// A snapshot of Apple Health data, one value per day.
struct HealthData: Codable {
    var steps: [DailyMetric] = []
    var activeEnergy: [DailyMetric] = []
    var restingHr: [DailyMetric] = []
    var hrv: [DailyMetric] = []
    var sleepHours: [DailyMetric] = []
    var bodyMassKg: [DailyMetric] = []
    var bodyFatPct: [DailyMetric] = []
    var vo2Max: [DailyMetric] = []
    var proteinG: [DailyMetric] = []
    var caloriesIn: [DailyMetric] = []
    var lastUpdated: Date?

    var isEmpty: Bool { steps.isEmpty && hrv.isEmpty && sleepHours.isEmpty && restingHr.isEmpty }
}

extension Array where Element == DailyMetric {
    var latest: DailyMetric? { self.max { $0.date < $1.date } }

    func average(lastDays days: Int, excludingLatest: Bool = false, now: Date = Date()) -> Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        var vals = self.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        if excludingLatest, !vals.isEmpty { vals.removeLast() }
        guard !vals.isEmpty else { return nil }
        return vals.map(\.value).reduce(0, +) / Double(vals.count)
    }

    func value(on day: Date) -> Double? {
        let cal = Calendar.current
        return first { cal.isDate($0.date, inSameDayAs: day) }?.value
    }
}
