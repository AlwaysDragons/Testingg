import EventKit
import Foundation
import Observation

/// Two-way sync between the `reminders` table and Apple Reminders (EventKit, on-device only).
/// You choose which Reminders lists sync and which area each maps to (stored on this device:
/// list ids are device-specific). Plans come from `ReminderMerge`; this type only executes them.
@Observable
@MainActor
final class ReminderSync {
    private let eventStore = EKEventStore()
    private(set) var authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    private(set) var lists: [EKCalendar] = []
    private(set) var isSyncing = false
    private(set) var lastSynced: Date?
    var lastError: String?

    /// calendarIdentifier → area id ("" = no area). Only lists in here sync.
    private(set) var mapping: [String: String] = UserDefaults.standard.dictionary(forKey: Keys.mapping) as? [String: String] ?? [:]
    /// The list new app/AI reminders go into (default: the system default list).
    var defaultListId: String? = UserDefaults.standard.string(forKey: Keys.defaultList) {
        didSet { UserDefaults.standard.set(defaultListId, forKey: Keys.defaultList) }
    }

    private enum Keys {
        static let mapping = "reminders.listMapping"
        static let defaultList = "reminders.defaultList"
    }

    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSync: Task<Void, Never>?
    @ObservationIgnored weak var store: LifeStore?

    init() {
        refreshLists()
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleSync() }
        }
    }

    // MARK: Access + lists

    /// Asks for Reminders access (in context, from Settings or the first reminder).
    func requestAccess() async -> Bool {
        do {
            authorized = try await eventStore.requestFullAccessToReminders()
        } catch {
            authorized = false
            lastError = error.localizedDescription
        }
        refreshLists()
        return authorized
    }

    func refreshLists() {
        authorized = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        lists = authorized ? eventStore.calendars(for: .reminder).sorted { $0.title < $1.title } : []
    }

    func isSynced(_ list: EKCalendar) -> Bool { mapping[list.calendarIdentifier] != nil }

    func setList(_ list: EKCalendar, synced: Bool, area: UUID? = nil) {
        if synced { mapping[list.calendarIdentifier] = area?.uuidString.lowercased() ?? "" } else { mapping.removeValue(forKey: list.calendarIdentifier) }
        UserDefaults.standard.set(mapping, forKey: Keys.mapping)
        scheduleSync()
    }

    func area(for list: EKCalendar) -> UUID? { mapping[list.calendarIdentifier].flatMap { UUID(uuidString: $0) } }

    // MARK: Sync

    func scheduleSync() {
        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard authorized, let store, let repo = store.repo, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let synced = lists.filter(isSynced)
        var apple = await fetch(in: synced)
        // Also look up reminders linked to rows that live in lists you don't sync (or were moved).
        let known = Set(apple.map(\.id))
        for id in store.reminders.compactMap(\.appleReminderId) where !known.contains(id) {
            if let r = eventStore.calendarItem(withIdentifier: id) as? EKReminder { apple.append(Self.snapshot(r)) }
        }
        let plan = ReminderMerge.plan(rows: store.reminders, apple: apple)
        guard !plan.isEmpty else { lastSynced = Date(); return }
        for action in plan {
            do { try await execute(action, repo: repo) } catch { lastError = error.localizedDescription }
        }
        lastSynced = Date()
        await store.reload(["reminders"])
    }

    private func execute(_ action: ReminderMerge.Action, repo: LifeRepository) async throws {
        switch action {
        case .createApple(let row):
            let r = EKReminder(eventStore: eventStore)
            r.calendar = targetList(for: row)
            apply(row, to: r)
            try eventStore.save(r, commit: true)
            try await repo.patch("reminders", id: row.id, ["apple_reminder_id": .string(r.calendarItemIdentifier), "sync_status": .string("synced"),
                                                           "source_modified_at": .of(r.lastModifiedDate ?? Date())])
        case .updateApple(let row, let appleId):
            guard let r = eventStore.calendarItem(withIdentifier: appleId) as? EKReminder else { return }
            apply(row, to: r)
            try eventStore.save(r, commit: true)
            try await repo.patch("reminders", id: row.id, ["sync_status": .string("synced"), "source_modified_at": .of(r.lastModifiedDate ?? Date())])
        case .deleteApple(let appleId, let rowId):
            if let r = eventStore.calendarItem(withIdentifier: appleId) as? EKReminder { try eventStore.remove(r, commit: true) }
            try await repo.delete("reminders", id: rowId)
        case .updateRow(let id, let ek):
            try await repo.patch("reminders", id: id, Self.fields(from: ek))
        case .importApple(let ek):
            var row = Self.fields(from: ek)
            row["apple_reminder_id"] = .string(ek.id)
            row["notify_mode"] = .string(ek.hasAlarm ? "reminders_app" : (store?.settings?.defaultNotifyMode ?? "app"))
            if let area = mapping[ek.listId], !area.isEmpty { row["area_id"] = .string(area) }
            try await repo.client.rest("POST", "reminders", query: [.init(name: "on_conflict", value: "user_id,apple_reminder_id")],
                                       body: try JSONEncoder().encode([row]), prefer: "resolution=merge-duplicates,return=minimal")
        case .deleteRow(let id):
            try await repo.delete("reminders", id: id)
        case .markSynced(let id, let modified):
            try await repo.patch("reminders", id: id, ["sync_status": .string("synced"), "source_modified_at": .of(modified ?? Date())])
        }
    }

    static func fields(from ek: AppleReminder) -> Row {
        ["title": .string(ek.title), "notes": .of(ek.notes), "remind_at": .of(ek.due), "completed_at": .of(ek.isCompleted ? (ek.completedAt ?? Date()) : nil),
         "sync_status": .string("synced"), "source_modified_at": .of(ek.lastModified ?? Date())]
    }

    // MARK: EventKit helpers

    private func targetList(for row: Reminder) -> EKCalendar? {
        if let area = row.areaId?.uuidString.lowercased(), let id = mapping.first(where: { $0.value == area })?.key,
           let list = eventStore.calendar(withIdentifier: id) { return list }
        if let id = defaultListId, let list = eventStore.calendar(withIdentifier: id) { return list }
        return eventStore.defaultCalendarForNewReminders()
    }

    private func apply(_ row: Reminder, to r: EKReminder) {
        r.title = row.title
        r.notes = row.notes
        if let at = row.remindAt {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        } else {
            r.dueDateComponents = nil
        }
        r.isCompleted = row.isDone
        if row.isDone { r.completionDate = row.completedAt }
        // notify_mode "reminders_app": the Reminders app alerts; otherwise the app (or nothing) does.
        r.alarms?.forEach { r.removeAlarm($0) }
        if row.notifyMode == "reminders_app", let at = row.remindAt { r.addAlarm(EKAlarm(absoluteDate: at)) }
        r.recurrenceRules?.forEach { r.removeRecurrenceRule($0) }
        if let rule = SimpleRRule(row.repeatRule) {
            let freq: EKRecurrenceFrequency
            switch rule.freq { case .daily: freq = .daily; case .weekly: freq = .weekly; case .monthly: freq = .monthly; case .yearly: freq = .yearly }
            r.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: freq, interval: rule.interval, end: nil))
        }
    }

    nonisolated static func snapshot(_ r: EKReminder) -> AppleReminder {
        AppleReminder(id: r.calendarItemIdentifier, listId: r.calendar?.calendarIdentifier ?? "", title: r.title ?? "",
                      notes: r.notes, due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                      isCompleted: r.isCompleted, completedAt: r.completionDate, lastModified: r.lastModifiedDate,
                      hasAlarm: !(r.alarms ?? []).isEmpty)
    }

    /// Open reminders plus those completed in the last 7 days, from the given lists.
    private func fetch(in lists: [EKCalendar]) async -> [AppleReminder] {
        guard !lists.isEmpty else { return [] }
        let open = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        let done = eventStore.predicateForCompletedReminders(withCompletionDateStarting: Date().addingTimeInterval(-7 * 86_400), ending: Date(), calendars: lists)
        return await fetch(open) + fetch(done)
    }

    private func fetch(_ predicate: NSPredicate) async -> [AppleReminder] {
        await withCheckedContinuation { cont in
            eventStore.fetchReminders(matching: predicate) { reminders in
                // Snapshot on the callback thread; EKReminder must not cross actors.
                let snaps = (reminders ?? []).map(ReminderSync.snapshot)
                cont.resume(returning: snaps)
            }
        }
    }
}
