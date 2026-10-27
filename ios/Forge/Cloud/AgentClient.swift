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

    /// The result of a task mode (briefing, capture, weekly review, ...).
    struct TaskReply<Result: Decodable>: Decodable {
        let result: Result
        let reply: String?
        let deviceActions: [DeviceAction]
        let toolCalls: [ToolCall]
        let toolResults: [ToolResultLog]?
    }

    struct ToolResultLog: Decodable {
        let name: String
        let result: JSONValue
    }

    /// Runs a one-shot task mode on the agent (not saved to chat history).
    func task<Result: Decodable>(_ mode: String, params: [String: JSONValue] = [:], as: Result.Type = Result.self) async throws -> TaskReply<Result> {
        let body = try JSONEncoder().encode(["mode": JSONValue.string(mode), "params": .object(params)])
        let data = try await supabase.invoke("ai-agent", body: body)
        return try await supabase.decode(TaskReply<Result>.self, from: data)
    }

    func send(_ message: String) async throws -> Reply {
        let body = try JSONEncoder().encode(["message": message])
        let data = try await supabase.invoke("ai-agent", body: body)
        return try await supabase.decode(Reply.self, from: data)
    }
}
