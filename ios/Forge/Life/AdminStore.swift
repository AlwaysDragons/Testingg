import Foundation
import Observation

struct Person: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var birthday: String?
    var lastContacted: Date?
    var notes: String?
    var giftIdeas: JSONValue
    var contactEveryDays: Int?

    var gifts: [String] { giftIdeas.array.compactMap(\.string) }
    /// Overdue for a catch-up (contact_every_days passed since last contact).
    func needsContact(now: Date = Date()) -> Bool {
        guard let every = contactEveryDays else { return false }
        guard let last = lastContacted else { return true }
        return now.timeIntervalSince(last) > Double(every) * 86_400
    }
}

struct Birthday: Decodable, Hashable, Sendable { var id: UUID; var name: String; var next: String; var turns: Int? }

struct LifeDocument: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var category: String?
    var notes: String?
    var locationNote: String?
    var expiresAt: String?
    var filePath: String?
}

/// People, documents (with private file storage), shopping lists and travel packing.
@Observable
@MainActor
final class AdminStore {
    private(set) var people: [Person] = []
    private(set) var birthdays: [Birthday] = []
    private(set) var documents: [LifeDocument] = []
    var lastError: String?
    private var client: SupabaseClient?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { people = []; documents = []; birthdays = []; return }
        let repo = LifeRepository(client: client)
        people = (try? await repo.get("people", ["select": "id,name,birthday,last_contacted,notes,gift_ideas,contact_every_days", "order": "name.asc"])) ?? []
        birthdays = (try? await repo.rpc("ai_upcoming_birthdays", ["p_days": .int(60)])) ?? []
        documents = (try? await repo.get("documents", ["select": "id,title,category,notes,location_note,expires_at,file_path", "order": "title.asc"])) ?? []
    }

    // MARK: People

    func savePerson(name: String, birthday: Date?, notes: String, gifts: [String], contactEvery: Int?) async {
        await call("ai_add_person", ["p": .object([
            "name": .string(name), "birthday": .of(birthday.map { LifeCoding.dayString($0) }), "notes": .string(notes),
            "gift_ideas": .of(gifts), "contact_every_days": .of(contactEvery),
        ])])
    }

    func logContact(_ p: Person) async { await call("ai_log_contact", ["p_person": .string(p.id.uuidString.lowercased())]) }

    func delete(_ p: Person) async { await call("ai_delete_person", ["p_id": .of(p.id)]) }

    // MARK: Documents

    func saveDocument(title: String, category: String?, location: String?, expires: Date?, notes: String?, file: Data?, fileExtension: String = "jpg") async {
        guard let client else { return }
        var path: String?
        if let file, let uid = await client.userId {
            path = "\(uid)/\(UUID().uuidString.lowercased()).\(fileExtension)"
            do {
                try await client.upload(bucket: "documents", path: path!, data: file, contentType: fileExtension == "pdf" ? "application/pdf" : "image/jpeg")
            } catch { lastError = error.localizedDescription; path = nil }
        }
        var p: [String: JSONValue] = ["title": .string(title), "expires_at": .of(expires.map { LifeCoding.dayString($0) })]
        if let category, !category.isEmpty { p["category"] = .string(category) }
        if let location { p["location_note"] = .string(location) }
        if let notes { p["notes"] = .string(notes) }
        if let path { p["file_path"] = .string(path) }
        await call("ai_save_document", ["p": .object(p)])
    }

    func delete(_ d: LifeDocument) async {
        guard let client else { return }
        if let path = d.filePath { try? await client.removeObject(bucket: "documents", path: path) }
        await call("ai_delete_document", ["p_id": .of(d.id)])
    }

    func fileURL(_ d: LifeDocument) async -> URL? {
        guard let client, let path = d.filePath else { return nil }
        return try? await client.signedURL(bucket: "documents", path: path, expiresIn: 600)
    }

    private func call(_ fn: String, _ args: Row) async {
        guard let client else { return }
        do {
            let _: JSONValue = try await LifeRepository(client: client).rpc(fn, args)
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await reload()
    }
}

/// Shopping lists: items in the Shopping area grouped by data.list. Trips: items in the Travel area with
/// data.destination/start/end; their packing list is milestones. Packing templates live in the area's config.
enum Admin {
    static func list(of item: Item) -> String { item.data["list"]?.string ?? "Groceries" }

    static func templates(_ area: Area) -> [String: [String]] {
        area.config["packing_templates"]?.object.mapValues { $0.array.compactMap(\.string) } ?? [:]
    }

    static func shareText(list: String, items: [Item]) -> String {
        ([list] + items.filter { !$0.isDone }.map { "• " + $0.title }).joined(separator: "\n")
    }
}

extension LifeStore {
    /// An area for life-admin lists, created (not pinned) on first use.
    func adminArea(named name: String, icon: String) async -> Area? {
        if let a = area(named: name) { return a }
        guard let a = await createArea(name: name, kind: name == "Shopping" ? "tasks" : "custom", icon: icon, color: nil) else { return nil }
        await updateArea(a, ["pinned": .bool(false)])
        return area(a.id)
    }
}
