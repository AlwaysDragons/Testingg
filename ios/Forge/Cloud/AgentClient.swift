import Foundation

/// Sends a chat message to the `ai-agent` Edge Function. The chat UI arrives in Phase 5;
/// on-device reminder writes (EventKit) arrive in Phase 5.5.
struct AgentClient {
    let supabase: SupabaseClient

    struct Reply: Decodable {
        let reply: String
        let deviceActions: [DeviceAction]
        let toolCalls: [ToolCall]
    }

    /// Something the app must do locally, e.g. mirror a reminder into Apple Reminders.
    struct DeviceAction: Decodable {
        let type: String            // "reminder.upsert" | "reminder.delete"
        let reminder: Reminder?
    }

    /// A `reminders` row as returned by the agent. Timestamps stay strings until Phase 5.5 parses them.
    struct Reminder: Decodable {
        let id: String
        let title: String
        let notes: String?
        let remindAt: String?
        let repeatRule: String?
        let notifyMode: String
        let appleReminderId: String?
        let areaId: String?
        let completedAt: String?
        let syncStatus: String
    }

    struct ToolCall: Decodable {
        let name: String
        let ok: Bool
        let error: String?
    }

    func send(_ message: String) async throws -> Reply {
        let body = try JSONEncoder().encode(["message": message])
        let data = try await supabase.invoke("ai-agent", body: body)
        return try await supabase.decode(Reply.self, from: data)
    }
}
