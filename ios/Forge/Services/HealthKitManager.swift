import Foundation
import HealthKit

/// Reads daily Apple Health metrics. Read-only.
final class HealthKitManager {
    private let store = HKHealthStore()
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let quantityIDs: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .restingHeartRate, .heartRateVariabilitySDNN,
        .bodyMass, .bodyFatPercentage, .vo2Max, .dietaryProtein, .dietaryEnergyConsumed
    ]

    private var readTypes: Set<HKObjectType> {
        var s: Set<HKObjectType> = [HKObjectType.workoutType()]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        for id in quantityIDs { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        return s
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func fetchAll(days: Int = 60) async -> HealthData {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let vo2 = HKUnit(from: "ml/kg*min")
        async let steps = daily(.stepCount, .count(), .cumulativeSum, days)
        async let energy = daily(.activeEnergyBurned, .kilocalorie(), .cumulativeSum, days)
        async let rhr = daily(.restingHeartRate, bpm, .discreteAverage, days)
        async let hrv = daily(.heartRateVariabilitySDNN, .secondUnit(with: .milli), .discreteAverage, days)
        async let mass = daily(.bodyMass, .gramUnit(with: .kilo), .discreteMostRecent, days * 3)
        async let fat = daily(.bodyFatPercentage, .percent(), .discreteMostRecent, days * 3)
        async let vo = daily(.vo2Max, vo2, .discreteMostRecent, days * 3)
        async let protein = daily(.dietaryProtein, .gram(), .cumulativeSum, days)
        async let kcal = daily(.dietaryEnergyConsumed, .kilocalorie(), .cumulativeSum, days)
        async let sleep = sleepHours(days: days)

        var h = HealthData()
        h.steps = await steps
        h.activeEnergy = await energy
        h.restingHr = await rhr
        h.hrv = await hrv
        h.bodyMassKg = await mass
        h.bodyFatPct = (await fat).map { DailyMetric(date: $0.date, value: $0.value * 100) }
        h.vo2Max = await vo
        h.proteinG = await protein
        h.caloriesIn = await kcal
        h.sleepHours = await sleep
        h.lastUpdated = Date()
        return h
    }

    private func daily(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ option: HKStatisticsOptions, _ days: Int) async -> [DailyMetric] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: option, anchorDate: start, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, _ in
                var out: [DailyMetric] = []
                results?.enumerateStatistics(from: start, to: end) { stat, _ in
                    let qty: HKQuantity?
                    if option.contains(.cumulativeSum) { qty = stat.sumQuantity() }
                    else if option.contains(.discreteMostRecent) { qty = stat.mostRecentQuantity() }
                    else { qty = stat.averageQuantity() }
                    if let qty { out.append(DailyMetric(date: stat.startDate, value: qty.doubleValue(for: unit))) }
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// Hours asleep per night, keyed to the wake-up day. Uses the single best source per night to avoid
    /// double-counting iPhone + Apple Watch.
    private func sleepHours(days: Int) async -> [DailyMetric] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: Date()))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date())
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        var perNight: [Date: [String: Double]] = [:]
        for s in samples where asleep.contains(s.value) {
            let day = cal.startOfDay(for: s.endDate)
            let src = s.sourceRevision.source.bundleIdentifier
            perNight[day, default: [:]][src, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 3600
        }
        return perNight.compactMap { day, sources in
            guard let best = sources.values.max(), best > 0.5 else { return nil }
            return DailyMetric(date: day, value: best)
        }
        .sorted { $0.date < $1.date }
    }
}
