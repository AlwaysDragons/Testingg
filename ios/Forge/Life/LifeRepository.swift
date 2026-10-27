import Foundation

/// Reads and writes the life-dashboard tables through PostgREST as the signed-in user (RLS applies).
struct LifeRepository: Sendable {
    let client: SupabaseClient

    // MARK: Reads

    func areas() async throws -> [Area] {
        try await get("areas", ["select": "*", "order": "sort_order.asc,name.asc"])
    }

    /// Open items plus items completed in the last 60 days.
    func items(now: Date = Date()) async throws -> [Item] {
        let since = LifeCoding.string(now.addingTimeInterval(-60 * 86_400))
        return try await get("items", ["select": "*", "or": "(status.neq.done,completed_at.gte.\"\(since)\")", "order": "due_date.asc.nullslast,created_at.asc", "limit": "2000"])
    }

    func logs(days: Int = 120, now: Date = Date()) async throws -> [LogEntry] {
        let since = LifeCoding.string(now.addingTimeInterval(-Double(days) * 86_400))
        return try await get("logs", ["select": "id,area_id,item_id,note,data,logged_at", "logged_at": "gte.\(since)", "order": "logged_at.desc", "limit": "3000"])
    }

    func metrics(days: Int = 400, now: Date = Date()) async throws -> [Metric] {
        let since = LifeCoding.string(now.addingTimeInterval(-Double(days) * 86_400))
        return try await get("metrics", ["select": "id,area_id,name,value,unit,recorded_at,data,source", "recorded_at": "gte.\(since)", "order": "recorded_at.asc", "limit": "10000"])
    }

    /// Open reminders plus those completed in the last 7 days.
    func reminders(now: Date = Date()) async throws -> [Reminder] {
        let since = LifeCoding.string(now.addingTimeInterval(-7 * 86_400))
        return try await get("reminders", ["select": "*", "or": "(completed_at.is.null,completed_at.gte.\"\(since)\")", "order": "remind_at.asc.nullslast"])
    }

    func settings() async throws -> UserSettings? {
        let rows: [UserSettings] = try await get("user_settings", ["select": "*", "limit": "1"])
        return rows.first
    }

    // MARK: Area writes

    @discardableResult
    func createArea(name: String, kind: String, icon: String?, color: String?, pinned: Bool = true, sortOrder: Int) async throws -> Area {
        try await insert("areas", ["name": .string(name), "kind": .string(kind), "icon": .of(icon), "color": .of(color), "pinned": .bool(pinned), "sort_order": .int(sortOrder)])
    }

    func updateArea(_ id: UUID, _ fields: Row) async throws {
        try await patch("areas", id: id, fields)
    }

    func deleteArea(_ id: UUID) async throws {
        try await delete("areas", id: id)
    }

    // MARK: Item writes

    @discardableResult
    func createItem(areaId: UUID, title: String, dueDate: Date? = nil, priority: Int = 0, recurrence: String? = nil, parentId: UUID? = nil, data: JSONValue = .emptyObject) async throws -> Item {
        try await insert("items", [
            "area_id": .of(areaId), "title": .string(title), "due_date": .of(dueDate), "priority": .int(priority),
            "recurrence": .of(recurrence), "parent_id": .of(parentId), "data": data,
        ])
    }

    func updateItem(_ id: UUID, _ fields: Row) async throws {
        try await patch("items", id: id, fields)
    }

    func setItemDone(_ id: UUID, done: Bool, now: Date = Date()) async throws {
        try await patch("items", id: id, done
            ? ["status": .string("done"), "progress": .int(100), "completed_at": .of(now)]
            : ["status": .string("not_started"), "completed_at": .null])
    }

    func deleteItem(_ id: UUID) async throws {
        try await delete("items", id: id)
    }

    // MARK: Logs + metrics

    @discardableResult
    func addLog(areaId: UUID, itemId: UUID? = nil, note: String?, data: JSONValue = .emptyObject, at date: Date = Date()) async throws -> LogEntry {
        try await insert("logs", ["area_id": .of(areaId), "item_id": .of(itemId), "note": .of(note), "data": data, "logged_at": .of(date)])
    }

    func deleteLog(_ id: UUID) async throws {
        try await delete("logs", id: id)
    }

    @discardableResult
    func addMetric(areaId: UUID, name: String, value: Double, unit: String?, data: JSONValue = .emptyObject, at date: Date = Date()) async throws -> Metric {
        try await insert("metrics", ["area_id": .of(areaId), "name": .string(name), "value": .number(value), "unit": .of(unit), "data": data, "recorded_at": .of(date), "source": .string("manual")])
    }

    // MARK: Settings

    func updateSettings(userId: String, _ fields: Row) async throws {
        try await client.rest("PATCH", "user_settings", query: [.init(name: "user_id", value: "eq.\(userId)")],
                              body: try JSONEncoder().encode(fields), prefer: "return=minimal")
    }

    // MARK: Generic helpers (also used by later features)

    func get<T: Decodable>(_ table: String, _ params: KeyValuePairs<String, String>) async throws -> T {
        let data = try await client.rest("GET", table, query: params.map { URLQueryItem(name: $0.key, value: $0.value) })
        return try LifeCoding.decoder.decode(T.self, from: data)
    }

    func insert<T: Decodable>(_ table: String, _ row: Row) async throws -> T {
        let data = try await client.rest("POST", table, query: [.init(name: "select", value: "*")],
                                         body: try JSONEncoder().encode([row]), prefer: "return=representation")
        guard let first = try LifeCoding.decoder.decode([T].self, from: data).first else { throw APIError.badResponse }
        return first
    }

    func patch(_ table: String, id: UUID, _ fields: Row) async throws {
        try await client.rest("PATCH", table, query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")],
                              body: try JSONEncoder().encode(fields), prefer: "return=minimal")
    }

    func delete(_ table: String, id: UUID) async throws {
        try await client.rest("DELETE", table, query: [.init(name: "id", value: "eq.\(id.uuidString.lowercased())")], prefer: "return=minimal")
    }

    /// Calls a Postgres function (`/rest/v1/rpc/<fn>`).
    func rpc<T: Decodable>(_ fn: String, _ args: Row = [:]) async throws -> T {
        let data = try await client.rest("POST", "rpc/\(fn)", body: try JSONEncoder().encode(args))
        return try LifeCoding.decoder.decode(T.self, from: data)
    }
}
