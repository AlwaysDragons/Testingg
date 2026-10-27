import Foundation
import Observation

struct Capture: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var rawText: String
    var source: String
    var routedAreaId: UUID?
    var routedItemId: UUID?
    var status: String          // inbox | sorted
    var data: JSONValue
    var createdAt: Date

    var summary: String? { data["summary"]?.string }
}

/// Quick capture: save first (never lose a thought), then let the agent sort it. Undo removes what it created.
@Observable
@MainActor
final class CaptureStore {
    private(set) var inbox: [Capture] = []
    private(set) var recent: [Capture] = []
    var isPresented = false
    var prefill = ""
    private var client: SupabaseClient?

    struct Outcome: Decodable, Sendable {
        let kind: String
        let summary: String
        let sorted: Bool
        let area: String?
    }

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { inbox = []; recent = []; return }
        let repo = LifeRepository(client: client)
        let rows: [Capture] = (try? await repo.get("captures", ["select": "*", "order": "created_at.desc", "limit": "60"])) ?? []
        inbox = rows.filter { $0.status == "inbox" }
        recent = rows.filter { $0.status == "sorted" }
    }

    func open(prefill: String = "") {
        self.prefill = prefill
        isPresented = true
    }

    /// Saves the capture, then routes it. Returns the capture id and the outcome (nil if routing failed;
    /// the capture then waits in the inbox).
    func capture(_ text: String, source: String = "text") async -> (UUID, Outcome?)? {
        guard let client else { return nil }
        return await Self.capture(text, source: source, client: client, after: { await self.reload() })
    }

    /// Also used by Siri / Action Button intents without the UI.
    nonisolated static func capture(_ text: String, source: String, client: SupabaseClient, after: @escaping @Sendable () async -> Void = {}) async -> (UUID, Outcome?)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let repo = LifeRepository(client: client)
        guard let saved: Capture = try? await repo.insert("captures", ["raw_text": .string(t), "source": .string(source)]) else { return nil }
        let outcome = try? await AgentClient(supabase: client)
            .task("capture", params: ["capture_id": .string(saved.id.uuidString.lowercased()), "text": .string(t), "source": .string(source)], as: Outcome.self)
            .result
        await after()
        return (saved.id, outcome)
    }

    /// Retries routing for something sitting in the inbox.
    func sort(_ capture: Capture) async -> Outcome? {
        guard let client else { return nil }
        let outcome = try? await AgentClient(supabase: client)
            .task("capture", params: ["capture_id": .string(capture.id.uuidString.lowercased()), "text": .string(capture.rawText), "source": .string(capture.source)], as: Outcome.self)
            .result
        await reload()
        return outcome
    }

    func undo(_ id: UUID) async {
        guard let client else { return }
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_undo_capture", ["p_id": .of(id)])
        await reload()
    }

    func delete(_ capture: Capture) async {
        guard let client else { return }
        try? await LifeRepository(client: client).delete("captures", id: capture.id)
        await reload()
    }
}
