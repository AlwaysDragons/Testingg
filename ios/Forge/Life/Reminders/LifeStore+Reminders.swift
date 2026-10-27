import Foundation

/// Reminder actions. Every change marks the row `pending_push` with a fresh `source_modified_at`,
/// so the on-device sync writes it to Apple Reminders and "most recent edit wins" holds.
extension LifeStore {
    func createReminder(title: String, at: Date, notifyMode: String? = nil, area: Area? = nil, repeatRule: String? = nil, notes: String? = nil) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let mode = notifyMode ?? settings?.defaultNotifyMode ?? "app"
        await perform { repo in
            let _: Reminder = try await repo.insert("reminders", [
                "title": .string(t), "remind_at": .of(at), "notify_mode": .string(mode), "area_id": .of(area?.id),
                "repeat_rule": .of(repeatRule), "notes": .of(notes), "sync_status": .string("pending_push"), "source_modified_at": .of(Date()),
            ])
        }
        await reload(["reminders"])
    }

    func updateReminder(_ r: Reminder, _ fields: Row) async {
        var f = fields
        f["sync_status"] = .string("pending_push")
        f["source_modified_at"] = .of(Date())
        await perform { try await $0.patch("reminders", id: r.id, f) }
        await reload(["reminders"])
    }

    func completeReminder(_ r: Reminder) async {
        await updateReminder(r, ["completed_at": .of(Date())])
    }

    func reopenReminder(_ r: Reminder) async {
        await updateReminder(r, ["completed_at": .null])
    }

    func snooze(_ r: Reminder, until date: Date) async {
        await updateReminder(r, ["remind_at": .of(date), "completed_at": .null])
    }

    /// In Apple Reminders → mark pending_delete (the sync removes both); otherwise delete now.
    func deleteReminder(_ r: Reminder) async {
        if r.appleReminderId != nil {
            await perform { try await $0.patch("reminders", id: r.id, ["sync_status": .string("pending_delete"), "source_modified_at": .of(Date())]) }
        } else {
            await perform { try await $0.delete("reminders", id: r.id) }
        }
        await reload(["reminders"])
    }

    /// Reminders grouped for the Reminders view.
    func reminderGroups(now: Date = Date(), calendar: Calendar = .current) -> (today: [Reminder], upcoming: [Reminder], done: [Reminder]) {
        let visible = reminders.filter { $0.syncStatus != "pending_delete" }
        let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(86_400)
        let open = visible.filter { !$0.isDone }
        let today = open.filter { ($0.remindAt ?? .distantFuture) < endOfToday }.sorted { ($0.remindAt ?? .distantPast) < ($1.remindAt ?? .distantPast) }
        let upcoming = open.filter { ($0.remindAt ?? .distantFuture) >= endOfToday }.sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
        let done = visible.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return (today, upcoming, done)
    }
}

/// Default time for a quick-added reminder: the next full hour, at least 30 minutes away.
enum ReminderDefaults {
    static func nextSlot(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let base = now.addingTimeInterval(30 * 60)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: base)
        let hour = calendar.date(from: comps) ?? base
        return hour < base ? hour.addingTimeInterval(3600) : hour
    }
}
