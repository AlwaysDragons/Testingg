import Foundation

/// Realistic sample data so the app looks alive before keys are connected.
enum DemoData {
    private struct Ex { let title: String; let startKg: Double; let reps: Int; let sets: Int }

    private static let split: [(String, [Ex])] = [
        ("Push", [Ex(title: "Bench Press (Barbell)", startKg: 80, reps: 8, sets: 4),
                  Ex(title: "Incline Bench Press (Dumbbell)", startKg: 28, reps: 10, sets: 3),
                  Ex(title: "Shoulder Press (Dumbbell)", startKg: 24, reps: 10, sets: 3),
                  Ex(title: "Lateral Raise (Dumbbell)", startKg: 10, reps: 15, sets: 4),
                  Ex(title: "Triceps Pushdown", startKg: 30, reps: 12, sets: 3)]),
        ("Pull", [Ex(title: "Lat Pulldown (Cable)", startKg: 65, reps: 10, sets: 4),
                  Ex(title: "Bent Over Row (Barbell)", startKg: 70, reps: 8, sets: 4),
                  Ex(title: "Seated Cable Row", startKg: 60, reps: 12, sets: 3),
                  Ex(title: "Face Pull", startKg: 25, reps: 15, sets: 3),
                  Ex(title: "Bicep Curl (Dumbbell)", startKg: 14, reps: 12, sets: 3)]),
        ("Legs", [Ex(title: "Squat (Barbell)", startKg: 100, reps: 6, sets: 4),
                  Ex(title: "Romanian Deadlift (Barbell)", startKg: 90, reps: 8, sets: 3),
                  Ex(title: "Leg Press", startKg: 180, reps: 12, sets: 3),
                  Ex(title: "Lying Leg Curl (Machine)", startKg: 45, reps: 12, sets: 3),
                  Ex(title: "Standing Calf Raise", startKg: 80, reps: 15, sets: 4)])
    ]

    static func workouts(weeks: Int = 16, now: Date = Date()) -> [HevyWorkout] {
        let cal = Calendar.current
        var out: [HevyWorkout] = []
        let trainingWeekdays = [2, 3, 5, 6, 7] // Mon Tue Thu Fri Sat
        var splitIndex = 0
        let start = cal.date(byAdding: .day, value: -weeks * 7, to: cal.startOfDay(for: now))!
        var day = start
        var session = 0
        while day < cal.startOfDay(for: now) {
            let wd = cal.component(.weekday, from: day)
            if trainingWeekdays.contains(wd), Int.random(in: 0..<10) > 0 {
                let (name, exs) = split[splitIndex % split.count]
                splitIndex += 1
                session += 1
                let begin = cal.date(bySettingHour: 17, minute: Int.random(in: 0...40), second: 0, of: day)!
                let progress = Double(session) / 3
                let exercises: [HevyExercise] = exs.enumerated().map { idx, e in
                    // Progressive overload with a plateau on the bench press for the last 4 weeks.
                    let stalled = e.title.hasPrefix("Bench") && session > (weeks * 5 - 20)
                    let gain = stalled ? Double(weeks * 5 - 20) / 3 * 0.02 : progress * 0.02
                    let kg = (e.startKg * (1 + gain) / 1.25).rounded() * 1.25
                    let warm = HevySet(index: 0, type: "warmup", weightKg: kg * 0.5, reps: 10, distanceMeters: nil, durationSeconds: nil, rpe: nil)
                    let work = (1...e.sets).map { i in
                        HevySet(index: i, type: "normal", weightKg: kg, reps: max(4, e.reps - (i > 2 ? 1 : 0) + Int.random(in: -1...1)),
                                distanceMeters: nil, durationSeconds: nil, rpe: 8)
                    }
                    return HevyExercise(index: idx, title: e.title, notes: nil, exerciseTemplateId: nil, supersetId: nil,
                                        sets: idx < 2 ? [warm] + work : work)
                }
                out.append(HevyWorkout(id: UUID().uuidString, title: name, description: nil, startTime: begin,
                                       endTime: begin.addingTimeInterval(Double.random(in: 55...75) * 60),
                                       updatedAt: begin, exercises: exercises))
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return out.sorted { $0.startTime > $1.startTime }
    }

    static func health(days: Int = 45, now: Date = Date()) -> HealthData {
        let cal = Calendar.current
        var h = HealthData()
        for i in (0..<days).reversed() {
            let d = cal.startOfDay(for: cal.date(byAdding: .day, value: -i, to: now)!)
            let dip = i == 0 ? -4.0 : 0
            h.steps.append(.init(date: d, value: Double.random(in: 6500...13000)))
            h.activeEnergy.append(.init(date: d, value: Double.random(in: 450...900)))
            h.restingHr.append(.init(date: d, value: Double.random(in: 52...58) + (i == 0 ? 1 : 0)))
            h.hrv.append(.init(date: d, value: Double.random(in: 52...72) + dip))
            h.sleepHours.append(.init(date: d, value: Double.random(in: 6.2...8.3) - (i == 0 ? 0.6 : 0)))
            if i % 2 == 0 { h.bodyMassKg.append(.init(date: d, value: 82 + Double(days - i) * 0.02 + Double.random(in: -0.4...0.4))) }
            if i % 7 == 0 { h.bodyFatPct.append(.init(date: d, value: 15.5 - Double(days - i) * 0.01)) }
            h.proteinG.append(.init(date: d, value: Double.random(in: 130...200)))
            h.caloriesIn.append(.init(date: d, value: Double.random(in: 2400...3100)))
        }
        h.vo2Max = [.init(date: cal.startOfDay(for: now), value: 46.2)]
        h.lastUpdated = now
        return h
    }
}
