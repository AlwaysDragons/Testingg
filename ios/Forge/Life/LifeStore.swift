import Foundation
import Observation

/// The life dashboard's state: everything loaded from Supabase, kept fresh by realtime.
/// Views read from here and call its actions; writes go to Supabase and realtime confirms them.
@Observable
@MainActor
final class LifeStore {
    private(set) var areas: [Area] = []
    private(set) var items: [Item] = []
    private(set) var logs: [LogEntry] = []
    private(set) var metrics: [Metric] = []
    private(set) var reminders: [Reminder] = []
    private(set) var settings: UserSettings?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var lastError: String?

    private(set) var repo: LifeRepository?
    private var realtime: RealtimeClient?
    private var pendingReload: Set<String> = []
    private var reloadTask: Task<Void, Never>?

    /// Device-only extras other features register (e.g. calendar events); not stored in Supabase.
    var onReloaded: [@MainActor () -> Void] = []

    // MARK: Connection

    /// Call when sign-in state changes. Loads everything and starts realtime.
    func connect(_ client: SupabaseClient?) async {
        guard let client else { disconnect(); return }
        if repo?.client === client { return }
        await realtime?.stop()
        repo = LifeRepository(client: client)
        let rt = RealtimeClient(client: client) { [weak self] table in
            Task { @MainActor in self?.scheduleReload(table) }
        }
        realtime = rt
        await reloadAll()
        await rt.start()
    }

    func disconnect() {
        let rt = realtime
        Task { await rt?.stop() }
        realtime = nil
        repo = nil
        areas = []; items = []; logs = []; metrics = []; reminders = []; settings = nil
        hasLoaded = false
    }

    var isConnected: Bool { repo != nil }

    // MARK: Loading

    func reloadAll() async {
        guard let repo else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let a = repo.areas()
            async let i = repo.items()
            async let l = repo.logs()
            async let m = repo.metrics()
            async let r = repo.reminders()
            async let s = repo.settings()
            (areas, items, logs, metrics, reminders, settings) = try await (a, i, l, m, r, s)
            hasLoaded = true
            lastError = nil
            onReloaded.forEach { $0() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Batches realtime events so a burst of changes causes one reload per table.
    private func scheduleReload(_ table: String) {
        pendingReload.insert(table)
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            let tables = self.pendingReload
            self.pendingReload = []
            await self.reload(tables)
        }
    }

    func reload(_ tables: Set<String>) async {
        guard let repo else { return }
        do {
            if tables.contains("areas") { areas = try await repo.areas() }
            if tables.contains("items") { items = try await repo.items() }
            if tables.contains("logs") { logs = try await repo.logs() }
            if tables.contains("metrics") { metrics = try await repo.metrics() }
            if tables.contains("reminders") { reminders = try await repo.reminders() }
            if tables.contains("user_settings") { settings = try await repo.settings() }
            onTableChange.forEach { $0(tables) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Other features (check-ins, captures, ...) reload their own tables on realtime events.
    var onTableChange: [@MainActor (Set<String>) -> Void] = []

    // MARK: Derived

    var visibleAreas: [Area] { areas.filter { !$0.hidden } }
    var homeAreas: [Area] { visibleAreas.filter(\.pinned) }

    func area(_ id: UUID?) -> Area? { id.flatMap { id in areas.first { $0.id == id } } }
    func area(named name: String) -> Area? { areas.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func items(in area: Area) -> [Item] { items.filter { $0.areaId == area.id } }
    func logs(in area: Area) -> [LogEntry] { logs.filter { $0.areaId == area.id } }
    func metrics(in area: Area) -> [Metric] { metrics.filter { $0.areaId == area.id } }
    func reminders(in area: Area) -> [Reminder] { reminders.filter { $0.areaId == area.id } }
    func children(of item: Item) -> [Item] { items.filter { $0.parentId == item.id } }

    func data(for area: Area, gym: (workouts: Int, target: Int)? = nil) -> Summaries.AreaData {
        Summaries.AreaData(area: area, items: items(in: area), logs: logs(in: area), metrics: metrics(in: area),
                           workoutsThisWeek: gym?.workouts, weeklyTarget: gym?.target)
    }

    var today: Summaries.Today { Summaries.today(items: items, reminders: reminders, logs: logs) }

    func isEnabled(_ feature: Feature) -> Bool { settings?.features[feature.rawValue]?.bool ?? false }

    // MARK: Actions (optimistic where it matters for feel; realtime reconciles)

    func perform(_ work: @escaping (LifeRepository) async throws -> Void) async {
        guard let repo else { return }
        do {
            try await work(repo)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setDone(_ item: Item, _ done: Bool) async {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].status = done ? "done" : "not_started"
            items[i].completedAt = done ? Date() : nil
            if done { items[i].progress = 100 }
        }
        await perform { try await $0.setItemDone(item.id, done: done) }
        await reload(["items"])
    }

    func delete(_ item: Item) async {
        items.removeAll { $0.id == item.id }
        await perform { try await $0.deleteItem(item.id) }
    }

    func addItem(to area: Area, title: String, due: Date? = nil, priority: Int = 0, recurrence: String? = nil, parent: Item? = nil) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        await perform { try await $0.createItem(areaId: area.id, title: t, dueDate: due, priority: priority, recurrence: recurrence, parentId: parent?.id) }
        await reload(["items"])
    }

    func update(_ item: Item, _ fields: Row) async {
        await perform { try await $0.updateItem(item.id, fields) }
        await reload(["items"])
    }

    func addLog(to area: Area, item: Item? = nil, note: String?, data: JSONValue = .emptyObject) async {
        await perform { try await $0.addLog(areaId: area.id, itemId: item?.id, note: note, data: data) }
        await reload(["logs"])
    }

    func addMetric(to area: Area, name: String, value: Double, unit: String?, data: JSONValue = .emptyObject) async {
        await perform { try await $0.addMetric(areaId: area.id, name: name, value: value, unit: unit, data: data) }
        await reload(["metrics"])
    }

    @discardableResult
    func createArea(name: String, kind: String, icon: String?, color: String?) async -> Area? {
        guard let repo else { return nil }
        do {
            let a = try await repo.createArea(name: name, kind: kind, icon: icon, color: color, sortOrder: (areas.map(\.sortOrder).max() ?? 0) + 1)
            await reload(["areas"])
            return a
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateArea(_ area: Area, _ fields: Row) async {
        await perform { try await $0.updateArea(area.id, fields) }
        await reload(["areas"])
    }

    func deleteArea(_ area: Area) async {
        await perform { try await $0.deleteArea(area.id) }
        await reload(["areas", "items", "logs", "metrics"])
    }

    /// Saves a new card order (sort_order = position).
    func reorder(_ ordered: [Area]) async {
        let changed = ordered.enumerated().filter { $0.element.sortOrder != $0.offset }
        for (i, a) in changed { if let idx = areas.firstIndex(where: { $0.id == a.id }) { areas[idx].sortOrder = i } }
        areas.sort { $0.sortOrder < $1.sortOrder }
        await perform { repo in for (i, a) in changed { try await repo.updateArea(a.id, ["sort_order": .int(i)]) } }
    }

    func setFeature(_ feature: Feature, _ on: Bool) async {
        guard let s = settings else { return }
        let features = s.features.setting(feature.rawValue, .bool(on))
        settings?.features = features
        await updateSettings(["features": features])
    }

    func updateSettings(_ fields: Row) async {
        guard let userId = await repo?.client.userId else { return }
        await perform { try await $0.updateSettings(userId: userId, fields) }
        await reload(["user_settings"])
    }
}
