import Foundation
import Observation

/// One chat line, from `ai_messages` or added locally while a reply is pending.
struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var role: String          // user | assistant
    var content: String?
    var createdAt: Date
    var isError = false
    var actions: [String] = []   // short confirmations of what the agent changed

    enum CodingKeys: String, CodingKey { case id, role, content, createdAt }
}

/// Chat with the `ai-agent` Edge Function. History comes from `ai_messages`; the agent saves both sides.
@Observable
@MainActor
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isSending = false
    /// Presentation state for the chat sheet (opened from the chat bar or "Ask about this").
    var isPresented = false
    var draft = ""

    private var client: SupabaseClient?
    /// Called with the reply's device actions (EventKit writes happen on-device, Phase 5.5).
    var onDeviceActions: [@MainActor ([AgentClient.DeviceAction]) async -> Void] = []

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        if client == nil { messages = [] } else { await reload() }
    }

    func reload() async {
        guard let client else { return }
        do {
            let repo = LifeRepository(client: client)
            let rows: [ChatMessage] = try await repo.get("ai_messages", [
                "select": "id,role,content,created_at", "role": "in.(user,assistant)",
                "order": "created_at.desc", "limit": "60",
            ])
            // Keep local-only lines (errors, pending) that the server doesn't have.
            let local = messages.filter { m in m.isError }
            let actionsById = Dictionary(messages.map { ($0.id, $0.actions) }, uniquingKeysWith: { a, _ in a })
            var merged = rows.reversed().map { row -> ChatMessage in
                var r = row
                r.actions = actionsById[row.id] ?? []
                return r
            }
            merged.append(contentsOf: local)
            messages = merged.sorted { $0.createdAt < $1.createdAt }
        } catch {
            // History is optional; sending still works.
        }
    }

    /// Opens the chat, optionally pre-filled ("Ask about this").
    func open(prefill: String? = nil) {
        if let prefill, draft.isEmpty { draft = prefill }
        isPresented = true
    }

    func send(_ text: String) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }
        guard let client else {
            messages.append(ChatMessage(id: UUID(), role: "assistant", content: "Sign in to cloud sync first.", createdAt: Date(), isError: true))
            return
        }
        messages.append(ChatMessage(id: UUID(), role: "user", content: message, createdAt: Date()))
        isSending = true
        defer { isSending = false }
        do {
            let reply = try await AgentClient(supabase: client).send(message)
            var line = ChatMessage(id: UUID(), role: "assistant", content: reply.reply, createdAt: Date())
            line.actions = Self.describe(reply.toolCalls)
            messages.append(line)
            for handler in onDeviceActions { await handler(reply.deviceActions) }
        } catch {
            messages.append(ChatMessage(id: UUID(), role: "assistant", content: Self.friendly(error), createdAt: Date(), isError: true))
        }
    }

    /// "Created 1 item", "Updated reminder" … from the tool calls that succeeded and wrote something.
    static func describe(_ calls: [AgentClient.ToolCall]) -> [String] {
        let labels: [String: String] = [
            "create_area": "Created area", "upsert_item": "Saved item", "complete_item": "Completed item", "delete_item": "Deleted item",
            "log_entry": "Logged", "record_metric": "Recorded", "create_reminder": "Created reminder", "update_reminder": "Updated reminder",
            "complete_reminder": "Completed reminder", "delete_reminder": "Deleted reminder",
        ]
        var counts: [(String, Int)] = []
        for call in calls where call.ok {
            guard let label = labels[call.name] else { continue }
            if let i = counts.firstIndex(where: { $0.0 == label }) { counts[i].1 += 1 } else { counts.append((label, 1)) }
        }
        return counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }
    }

    static func friendly(_ error: Error) -> String {
        if case APIError.http(let code, _) = error {
            switch code {
            case 401: return "Your session expired. Sign in again in Settings."
            case 404: return "The assistant isn't deployed yet. See Phase 3 in SETUP.md."
            case 429: return "Too many requests. Try again in a minute."
            default: return "The assistant couldn't answer (\(code)). Try again."
            }
        }
        return "Couldn't reach the assistant. Check your connection."
    }
}
