import Foundation

/// A data provider that feeds the shared Supabase tables.
/// New providers (Reminders, Calendar, ...) conform to this without touching core code.
protocol Integration: Sendable {
    /// Matches `integrations.provider`.
    var provider: String { get }
    var displayName: String { get }
    /// Pushes everything changed since `cursor` (nil = full backfill). Returns what was pushed and the new cursor.
    func sync(repo: CloudRepository, cursor: Date?) async throws -> SyncResult
}

struct SyncResult: Sendable {
    var pushed: Int
    var cursor: Date?
    var summary: String
}
