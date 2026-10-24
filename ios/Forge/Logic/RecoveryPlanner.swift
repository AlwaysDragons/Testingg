import Foundation

/// OneLife Fitness recovery amenities.
enum Modality: String, CaseIterable, Codable, Identifiable {
    case sauna, coldPlunge, hotTub, hydroMassage, compression
    var id: String { rawValue }

    var name: String {
        switch self {
        case .sauna: return "Sauna"
        case .coldPlunge: return "Cold Plunge"
        case .hotTub: return "Hot Tub"
        case .hydroMassage: return "HydroMassage"
        case .compression: return "Compression Sleeves"
        }
    }

    var icon: String {
        switch self {
        case .sauna: return "flame.fill"
        case .coldPlunge: return "snowflake"
        case .hotTub: return "bathtub.fill"
        case .hydroMassage: return "water.waves"
        case .compression: return "figure.cooldown"
        }
    }
}

struct RecoveryItem: Identifiable, Hashable {
    let id = UUID()
    let modality: Modality
    let timing: String
    let minutes: Int
    let dose: String
    let why: String
}

struct DayPlan: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let isTraining: Bool
    let focus: TrainingCategory?
    let completedTitle: String?
    let items: [RecoveryItem]
    let notes: [String]

    var headline: String {
        if let t = completedTitle { return "Done · \(t)" }
        if isTraining { return focus.map { "\($0.display) day" } ?? "Training day" }
        return "Rest & recover"
    }

    func minutes(of m: Modality) -> Int { items.filter { $0.modality == m }.reduce(0) { $0 + $1.minutes } }
}

enum RecoveryPlanner {
    /// Builds a 7-day OneLife recovery plan.
    ///
    /// Evidence-informed rules:
    /// - No cold plunge within ~6 h after lifting: cold water blunts hypertrophy signaling (Roberts et al., 2015).
    ///   Cold goes on rest days instead (≈11 min/week total, Søberg et al., 2021).
    /// - Sauna post-lift is fine and helps cardiovascular health; ~57 min/week total (Laukkanen et al.).
    /// - Compression after leg days and the day after; hydromassage after training or on rest days.
    /// - Hot tub 60–90 min before bed improves sleep onset, especially when sleep is short.
    static func plan(days: Int = 7,
                     trainingDays: Set<Int>,
                     workouts: [HevyWorkout],
                     resolver: MuscleResolver,
                     amenities: Set<Modality>,
                     readiness: Readiness?,
                     lastSleepHours: Double?,
                     now: Date = Date()) -> [DayPlan] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var plans: [DayPlan] = []
        var prevFocus: TrainingCategory?
        var prevTraining = false
        // Rotation model: the main category trained least recently comes next.
        var rotation = Analyzer.lastTrainedMain(workouts, resolver: resolver, now: now)

        if let y = cal.date(byAdding: .day, value: -1, to: today) {
            let yw = workouts.filter { cal.isDate($0.startTime, inSameDayAs: y) }
            prevTraining = !yw.isEmpty
            prevFocus = yw.first.map { resolver.category(of: $0) }
        }

        for i in 0..<days {
            let date = cal.date(byAdding: .day, value: i, to: today)!
            let wd = cal.component(.weekday, from: date)
            let doneToday = workouts.first { cal.isDate($0.startTime, inSameDayAs: date) }
            let isTraining = doneToday != nil || trainingDays.contains(wd)
            var focus: TrainingCategory?
            if let done = doneToday {
                focus = resolver.category(of: done)
            } else if isTraining {
                focus = Analyzer.weekdayFocus(weekday: wd, workouts: workouts, resolver: resolver, now: now)
                    ?? (rotation.isEmpty ? nil : rotation.min { $0.value < $1.value }?.key)
            }
            if let f = focus, [.push, .pull, .legs].contains(f) { rotation[f] = date.addingTimeInterval(12 * 3600) }
            let lowReadiness = i == 0 && (readiness?.score ?? 100) < 50
            let shortSleep = i == 0 && (lastSleepHours ?? 8) < 6.5

            var items: [RecoveryItem] = []
            var notes: [String] = []

            if isTraining {
                items.append(.init(modality: .sauna, timing: "Post-workout", minutes: 15, dose: "15–20 min · 170–190°F",
                                   why: "Heat after lifting boosts blood flow and cardiovascular adaptation without hurting gains. Drink 16–24 oz water."))
                if focus == .legs {
                    items.append(.init(modality: .compression, timing: "Post-workout or evening", minutes: 30, dose: "30 min · medium pressure",
                                       why: "Pneumatic compression reduces leg soreness and speeds clearance after heavy lower-body work."))
                    items.append(.init(modality: .hydroMassage, timing: "Post-workout", minutes: 10, dose: "10 min · lower back & glutes",
                                       why: "Loosens hips and lower back after squats and hinges."))
                } else {
                    items.append(.init(modality: .hydroMassage, timing: "Post-workout", minutes: 10, dose: "10–15 min · back & shoulders",
                                       why: "Relaxes traps, lats and upper back after pressing and pulling."))
                }
                notes.append("Skip the cold plunge today — within ~6 h of lifting it blunts muscle growth.")
                if shortSleep || lowReadiness {
                    items.append(.init(modality: .hotTub, timing: "Evening, 60–90 min before bed", minutes: 12, dose: "10–15 min · 102–104°F",
                                       why: "Warming then cooling down helps you fall asleep faster after a short night."))
                }
                if lowReadiness {
                    notes.append("Readiness is low — cut volume ~30% or swap for a mobility + recovery session.")
                }
            } else {
                items.append(.init(modality: .sauna, timing: "Contrast round 1–3", minutes: 15, dose: "3 × 5 min · 175–190°F",
                                   why: "Contrast therapy on rest days improves circulation and recovery."))
                items.append(.init(modality: .coldPlunge, timing: "After each sauna round", minutes: 4, dose: "3 × 1–2 min · 50–55°F",
                                   why: "Rest days are the right time for cold: big dopamine and recovery boost, no growth penalty. End on cold."))
                items.append(.init(modality: .hydroMassage, timing: "Any time", minutes: 15, dose: "15 min · full body",
                                   why: "Lowers muscle tension and stress on recovery days."))
                if prevFocus == .legs && prevTraining {
                    items.append(.init(modality: .compression, timing: "Midday or evening", minutes: 30, dose: "30 min · medium–high",
                                       why: "The day after legs is peak soreness — compression helps most here."))
                }
                items.append(.init(modality: .hotTub, timing: "Evening", minutes: 12, dose: "10–15 min · 102–104°F",
                                   why: "Light mobility in warm water, then helps sleep onset."))
                notes.append("Add a 20–30 min walk for active recovery.")
            }

            items = items.filter { amenities.contains($0.modality) }
            plans.append(DayPlan(date: date, isTraining: isTraining, focus: focus, completedTitle: doneToday?.title, items: items, notes: notes))
            prevFocus = focus
            prevTraining = isTraining
        }
        return plans
    }
}
