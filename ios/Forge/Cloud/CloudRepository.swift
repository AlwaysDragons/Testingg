import Foundation

/// Repository over the Supabase tables used by integrations. All writes are idempotent upserts.
struct CloudRepository {
    let client: SupabaseClient
    private let chunk = 200

    struct IntegrationState: Decodable {
        struct Config: Decodable { let cursor: String? }
        let provider: String
        let status: String
        let lastSyncedAt: String?
        let config: Config?
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: Areas

    /// Returns the id of the area with this name (case-insensitive), creating it if missing.
    func ensureArea(name: String, kind: String, icon: String) async throws -> UUID {
        struct IdRow: Decodable { let id: UUID }
        let found = try await client.rest("GET", "areas", query: [
            .init(name: "select", value: "id"),
            .init(name: "name", value: "ilike.\(name)"),
            .init(name: "limit", value: "1")
        ])
        if let row = try await client.decode([IdRow].self, from: found).first { return row.id }
        let body = try JSONEncoder().encode([["name": JSONValue.string(name), "kind": .string(kind), "icon": .string(icon), "pinned": .bool(true)]])
        let created = try await client.rest("POST", "areas", query: [.init(name: "select", value: "id")], body: body, prefer: "return=representation")
        guard let row = try await client.decode([IdRow].self, from: created).first else { throw APIError.badResponse }
        return row.id
    }

    // MARK: Integration state

    func integrationState(_ provider: String) async throws -> IntegrationState? {
        let data = try await client.rest("GET", "integrations", query: [
            .init(name: "select", value: "provider,status,last_synced_at,config"),
            .init(name: "provider", value: "eq.\(provider)")
        ])
        return try await client.decode([IntegrationState].self, from: data).first
    }

    /// Upserts the integration row. `config` must never contain secrets (the database rejects common secret keys).
    func setIntegration(_ provider: String, status: String, lastSyncedAt: Date?, cursor: Date?) async throws {
        var row: Row = ["provider": .string(provider), "status": .string(status)]
        if let lastSyncedAt { row["last_synced_at"] = .of(lastSyncedAt) }
        if let cursor { row["config"] = .object(["cursor": .of(cursor)]) }
        try await client.rest("POST", "integrations", query: [.init(name: "on_conflict", value: "user_id,provider")],
                              body: try JSONEncoder().encode([row]), prefer: "resolution=merge-duplicates,return=minimal")
    }

    // MARK: Hevy

    /// Upserts workouts on (user_id, hevy_id). Returns hevy_id → row id.
    func upsertWorkouts(_ rows: [Row]) async throws -> [String: UUID] {
        struct Ref: Decodable { let id: UUID; let hevyId: String }
        var out: [String: UUID] = [:]
        for part in rows.chunked(chunk) {
            let data = try await client.rest("POST", "workouts", query: [
                .init(name: "on_conflict", value: "user_id,hevy_id"),
                .init(name: "select", value: "id,hevy_id")
            ], body: try JSONEncoder().encode(Array(part)), prefer: "resolution=merge-duplicates,return=representation")
            for r in try await client.decode([Ref].self, from: data) { out[r.hevyId] = r.id }
        }
        return out
    }

    /// Replaces all sets of the given workouts (handles sets edited or removed in Hevy).
    func replaceSets(workoutIds: [UUID], rows: [Row]) async throws {
        for ids in workoutIds.chunked(50) {
            let list = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
            try await client.rest("DELETE", "workout_sets", query: [.init(name: "workout_id", value: "in.(\(list))")], prefer: "return=minimal")
        }
        for part in rows.chunked(chunk) {
            try await client.rest("POST", "workout_sets", query: [.init(name: "on_conflict", value: "workout_id,exercise_index,set_index")],
                                  body: try JSONEncoder().encode(Array(part)), prefer: "resolution=merge-duplicates,return=minimal")
        }
    }

    // MARK: Metrics

    /// Upserts metrics on (user_id, source, external_id).
    func upsertMetrics(_ rows: [Row]) async throws {
        for part in rows.chunked(chunk) {
            try await client.rest("POST", "metrics", query: [.init(name: "on_conflict", value: "user_id,source,external_id")],
                                  body: try JSONEncoder().encode(Array(part)), prefer: "resolution=merge-duplicates,return=minimal")
        }
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
