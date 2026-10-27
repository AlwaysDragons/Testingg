import Foundation

/// Adapter: pushes Hevy workouts already fetched by the existing `HevyClient`/`AppModel` into
/// `workouts` + `workout_sets`. It never calls the Hevy API itself, so the existing sync stays the source.
struct HevyIntegration: Integration {
    let provider = "hevy"
    let displayName = "Hevy"
    /// Snapshot of `AppModel.workouts` (existing cache).
    let workouts: [HevyWorkout]

    func sync(repo: CloudRepository, cursor: Date?) async throws -> SyncResult {
        // Incremental by date: only workouts created/edited after the last pushed one.
        let changed = workouts.filter { w in cursor.map { (w.updatedAt ?? w.endTime) > $0 } ?? true }
        guard !changed.isEmpty else { return SyncResult(pushed: 0, cursor: cursor, summary: "Up to date") }

        let gym = try await repo.ensureArea(name: "Gym", kind: "gym", icon: "dumbbell")
        let ids = try await repo.upsertWorkouts(Self.workoutRows(changed, gymArea: gym))
        let setRows = Self.setRows(changed, workoutIds: ids)
        try await repo.replaceSets(workoutIds: Array(ids.values), rows: setRows)

        let newCursor = changed.map { $0.updatedAt ?? $0.endTime }.max()
        return SyncResult(pushed: changed.count, cursor: newCursor ?? cursor,
                          summary: "\(changed.count) workouts, \(setRows.count) sets")
    }

    static func workoutRows(_ workouts: [HevyWorkout], gymArea: UUID) -> [Row] {
        workouts.map { w in
            [
                "hevy_id": .string(w.id),
                "area_id": .of(gymArea),
                "title": .string(w.title),
                "description": .of(w.description),
                "started_at": .of(w.startTime),
                "ended_at": .of(w.endTime),
                "hevy_updated_at": .of(w.updatedAt),
                "data": .object([
                    "duration_min": .number(w.durationMinutes.rounded()),
                    "working_sets": .int(w.workingSetCount),
                    "tonnage_kg": .number(w.tonnageKg.rounded())
                ])
            ]
        }
    }

    /// One row per set. `workoutIds` maps hevy_id → Supabase workout id.
    static func setRows(_ workouts: [HevyWorkout], workoutIds: [String: UUID]) -> [Row] {
        var rows: [Row] = []
        for w in workouts {
            guard let workoutId = workoutIds[w.id] else { continue }
            for (ei, e) in w.exercises.enumerated() {
                for (si, s) in e.sets.enumerated() {
                    rows.append([
                        "workout_id": .of(workoutId),
                        "exercise_index": .int(e.index ?? ei),
                        "exercise_title": .string(e.title),
                        "exercise_template_id": .of(e.exerciseTemplateId),
                        "superset_id": .of(e.supersetId),
                        "set_index": .int(s.index ?? si),
                        "set_type": .of(s.type),
                        "weight_kg": .of(s.weightKg),
                        "reps": .of(s.reps),
                        "distance_meters": .of(s.distanceMeters),
                        "duration_seconds": .of(s.durationSeconds),
                        "rpe": .of(s.rpe),
                        "notes": .of(si == 0 ? e.notes.flatMap { $0.isEmpty ? nil : $0 } : nil)
                    ])
                }
            }
        }
        return rows
    }
}
