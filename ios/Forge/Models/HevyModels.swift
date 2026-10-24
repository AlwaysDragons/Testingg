import Foundation

// MARK: - Hevy API models (https://api.hevyapp.com/docs)

struct HevyWorkout: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let description: String?
    let startTime: Date
    let endTime: Date
    let updatedAt: Date?
    let exercises: [HevyExercise]

    var durationMinutes: Double { max(0, endTime.timeIntervalSince(startTime) / 60) }
    var workingSetCount: Int { exercises.reduce(0) { $0 + $1.workingSets.count } }
    var tonnageKg: Double { exercises.reduce(0) { $0 + $1.tonnageKg } }
}

struct HevyExercise: Codable, Hashable {
    let index: Int?
    let title: String
    let notes: String?
    let exerciseTemplateId: String?
    let supersetId: Int?
    let sets: [HevySet]

    var workingSets: [HevySet] { sets.filter { $0.type != "warmup" } }
    var tonnageKg: Double { workingSets.reduce(0) { $0 + ($1.weightKg ?? 0) * Double($1.reps ?? 0) } }

    /// Best estimated 1RM across working sets (Epley).
    var bestE1RM: Double? {
        workingSets.compactMap { $0.e1RM }.max()
    }

    var topSet: HevySet? {
        workingSets.max { ($0.e1RM ?? 0) < ($1.e1RM ?? 0) }
    }
}

struct HevySet: Codable, Hashable {
    let index: Int?
    let type: String?
    let weightKg: Double?
    let reps: Int?
    let distanceMeters: Double?
    let durationSeconds: Double?
    let rpe: Double?

    var e1RM: Double? {
        guard let w = weightKg, w > 0, let r = reps, r > 0 else { return nil }
        if r == 1 { return w }
        return w * (1 + Double(min(r, 15)) / 30)
    }
}

struct HevyExerciseTemplate: Codable, Hashable {
    let id: String
    let title: String
    let type: String?
    let primaryMuscleGroup: String?
    let secondaryMuscleGroups: [String]?
    let isCustom: Bool?
}

// MARK: - Muscle groups

enum TrainingCategory: String, Codable, CaseIterable {
    case push, pull, legs, core, cardio, other

    var display: String { rawValue.capitalized }
}

enum MuscleGroup: String, Codable, CaseIterable {
    case chest, shoulders, triceps, biceps, forearms, lats
    case upperBack = "upper_back", traps, lowerBack = "lower_back", neck
    case abdominals, quadriceps, hamstrings, glutes, calves, abductors, adductors
    case cardio, fullBody = "full_body", other

    var display: String {
        switch self {
        case .upperBack: return "Upper Back"
        case .lowerBack: return "Lower Back"
        case .fullBody: return "Full Body"
        case .quadriceps: return "Quads"
        case .abdominals: return "Abs"
        default: return rawValue.capitalized
        }
    }

    var category: TrainingCategory {
        switch self {
        case .chest, .shoulders, .triceps: return .push
        case .biceps, .forearms, .lats, .upperBack, .traps, .lowerBack, .neck: return .pull
        case .quadriceps, .hamstrings, .glutes, .calves, .abductors, .adductors: return .legs
        case .abdominals: return .core
        case .cardio: return .cardio
        case .fullBody, .other: return .other
        }
    }

    /// Groups that matter for hypertrophy volume tracking.
    static let tracked: [MuscleGroup] = [.chest, .shoulders, .triceps, .lats, .upperBack, .biceps, .quadriceps, .hamstrings, .glutes, .calves, .abdominals]

    /// Fallback when a workout has no template info (e.g. demo data or a custom exercise).
    static func guess(fromTitle title: String) -> MuscleGroup {
        let s = title.lowercased()
        let rules: [([String], MuscleGroup)] = [
            (["treadmill", "elliptical", "stair", "bike", "cycling", "running", "rowing machine", "walk"], .cardio),
            (["bench", "chest", "fly", "pec", "push up", "push-up", "dip", "incline"], .chest),
            (["leg press", "squat", "lunge", "leg extension", "hack", "split squat"], .quadriceps),
            (["deadlift", "rdl", "romanian", "leg curl", "hamstring", "good morning"], .hamstrings),
            (["hip thrust", "glute", "kickback"], .glutes),
            (["calf"], .calves),
            (["crunch", "plank", "leg raise", "ab wheel", "sit up", "cable crunch"], .abdominals),
            (["pulldown", "pull up", "pull-up", "chin", "lat pull", "pullover"], .lats),
            (["row", "face pull", "rear delt", "reverse fly"], .upperBack),
            (["shrug"], .traps),
            (["tricep", "pushdown", "skull", "overhead extension"], .triceps),
            (["curl"], .biceps),
            (["press", "raise", "shoulder", "delt", "arnold"], .shoulders)
        ]
        for (keys, group) in rules where keys.contains(where: { s.contains($0) }) {
            return group
        }
        return .other
    }
}
