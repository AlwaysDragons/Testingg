import SwiftUI
import EventKit

/// Reminders grouped Today / Upcoming / Done. Swipe to complete or snooze; quick add with a bell toggle.
struct RemindersView: View {
    @Environment(LifeStore.self) private var store
    @Environment(ReminderSync.self) private var sync
    @State private var newTitle = ""
    @State private var notify = true
    @State private var editing: Reminder?

    var body: some View {
        let groups = store.reminderGroups()
        List {
            Section {
                HStack {
                    TextField("New reminder", text: $newTitle)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button { notify.toggle() } label: {
                        Image(systemName: notify ? "bell" : "bell.slash").foregroundStyle(notify ? DS.Palette.primary : DS.Palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(notify ? "Notify on" : "Notify off")
                }
            } footer: {
                Text("Added for \(ReminderDefaults.nextSlot().formatted(date: .omitted, time: .shortened)). Tap a reminder to change it.")
            }
            .listRowBackground(DS.Palette.surface)

            if groups.today.isEmpty && groups.upcoming.isEmpty && groups.done.isEmpty {
                Section { EmptyState(symbol: "bell", title: "No reminders", message: "Add one above, or ask the assistant.") }
                    .listRowBackground(DS.Palette.surface)
            }
            section("Today", groups.today)
            section("Upcoming", groups.upcoming)
            section("Done", Array(groups.done.prefix(20)))
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Reminders")
        .refreshable {
            await store.reload(["reminders"])
            await sync.sync()
        }
        .sheet(item: $editing) { ReminderEditor(reminder: $0) }
    }

    @ViewBuilder
    private func section(_ title: String, _ reminders: [Reminder]) -> some View {
        if !reminders.isEmpty {
            Section {
                ForEach(reminders) { r in ReminderRow(reminder: r) { editing = r } }
            } header: { SectionHeader(title: title) }
            .listRowBackground(DS.Palette.surface)
        }
    }

    private func add() {
        let title = newTitle
        newTitle = ""
        let mode = notify ? (store.settings?.defaultNotifyMode == "none" ? "app" : store.settings?.defaultNotifyMode ?? "app") : "none"
        Task {
            if mode == "app" { await NotificationScheduler.shared.requestPermission() }
            await store.createReminder(title: title, at: ReminderDefaults.nextSlot(), notifyMode: mode)
        }
    }
}

/// One reminder with swipe actions (done / snooze / delete).
struct ReminderRow: View {
    @Environment(LifeStore.self) private var store
    let reminder: Reminder
    let onTap: () -> Void

    var body: some View {
        let area = store.area(reminder.areaId)
        let overdue = !reminder.isDone && (reminder.remindAt ?? .distantFuture) < Date()
        Button(action: onTap) {
            ListRow(title: reminder.title, subtitle: subtitle(area), symbol: reminder.isDone ? "checkmark.circle.fill" : modeSymbol,
                    accent: reminder.isDone ? DS.Palette.positive : DS.Palette.secondary, isDone: reminder.isDone) {
                if let at = reminder.remindAt, !reminder.isDone {
                    RowValue(text: at.formatted(date: Calendar.current.isDateInToday(at) ? .omitted : .abbreviated, time: .shortened),
                             color: overdue ? DS.Palette.critical : DS.Palette.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if reminder.isDone {
                Button("Reopen", systemImage: "arrow.uturn.backward") { Task { await store.reopenReminder(reminder) } }
            } else {
                Button("Done", systemImage: "checkmark") {
                    DS.Haptics.success()
                    Task { await store.completeReminder(reminder) }
                }
                .tint(DS.Palette.positive)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.deleteReminder(reminder) } }
            if !reminder.isDone {
                Button("Snooze 1 hour", systemImage: "clock") { snooze(3600) }
                    .tint(DS.Palette.warning)
            }
        }
        .contextMenu {
            if !reminder.isDone {
                Button("Snooze 10 minutes", systemImage: "clock") { snooze(600) }
                Button("Snooze 1 hour", systemImage: "clock") { snooze(3600) }
                Button("Tomorrow", systemImage: "sunrise") {
                    Task { await store.snooze(reminder, until: Calendar.current.date(byAdding: .day, value: 1, to: max(reminder.remindAt ?? Date(), Date())) ?? Date()) }
                }
            }
        }
    }

    private var modeSymbol: String {
        switch reminder.notifyMode {
        case "none": return "bell.slash"
        case "reminders_app": return "list.bullet"
        default: return "bell"
        }
    }

    private func subtitle(_ area: Area?) -> String? {
        [area?.name, SimpleRRule(reminder.repeatRule)?.label].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private func snooze(_ seconds: TimeInterval) {
        Task { await store.snooze(reminder, until: Date().addingTimeInterval(seconds)) }
    }
}

/// Edit a reminder: title, time, repeat, notify mode, area, notes.
struct ReminderEditor: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let reminder: Reminder

    @State private var title = ""
    @State private var at = Date()
    @State private var repeatRule = ""
    @State private var mode = "app"
    @State private var areaId: UUID?
    @State private var notes = ""

    private let repeats: [(String, String)] = [("", "Never"), ("FREQ=DAILY", "Every day"), ("FREQ=WEEKLY", "Every week"),
                                               ("FREQ=MONTHLY", "Every month"), ("FREQ=YEARLY", "Every year")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker("When", selection: $at)
                    Picker("Repeat", selection: $repeatRule) {
                        ForEach(repeats, id: \.0) { Text($0.1).tag($0.0) }
                        if !repeats.contains(where: { $0.0 == repeatRule }) { Text(SimpleRRule(repeatRule)?.label ?? repeatRule).tag(repeatRule) }
                    }
                }
                .listRowBackground(DS.Palette.surface)
                Section {
                    Picker("Notify", selection: $mode) {
                        Text("App notification").tag("app")
                        Text("Reminders app").tag("reminders_app")
                        Text("Silent").tag("none")
                    }
                    Picker("Area", selection: $areaId) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.visibleAreas) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear {
                title = reminder.title
                at = reminder.remindAt ?? ReminderDefaults.nextSlot()
                repeatRule = reminder.repeatRule ?? ""
                mode = reminder.notifyMode
                areaId = reminder.areaId
                notes = reminder.notes ?? ""
            }
        }
    }

    private func save() async {
        if mode == "app" { await NotificationScheduler.shared.requestPermission() }
        await store.updateReminder(reminder, [
            "title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "remind_at": .of(at),
            "repeat_rule": repeatRule.isEmpty ? .null : .string(repeatRule), "notify_mode": .string(mode),
            "area_id": .of(areaId), "notes": notes.isEmpty ? .null : .string(notes),
        ])
        dismiss()
    }
}

/// Settings → Reminders and notifications.
struct RemindersSettingsView: View {
    @Environment(LifeStore.self) private var store
    @Environment(ReminderSync.self) private var sync

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { store.settings?.notificationsEnabled ?? false },
                    set: { on in
                        Task {
                            if on { await NotificationScheduler.shared.requestPermission() }
                            await store.updateSettings(["notifications_enabled": .bool(on)])
                        }
                    }))
                Picker("Default for new reminders", selection: Binding(
                    get: { store.settings?.defaultNotifyMode ?? "app" },
                    set: { v in Task { await store.updateSettings(["default_notify_mode": .string(v)]) } })) {
                    Text("App notification").tag("app")
                    Text("Reminders app").tag("reminders_app")
                    Text("Silent").tag("none")
                }
                timeRow("Quiet hours start", key: "quiet_hours_start", value: store.settings?.quietHoursStart, fallback: "22:00")
                timeRow("Quiet hours end", key: "quiet_hours_end", value: store.settings?.quietHoursEnd, fallback: "07:00")
                timeRow("Daily briefing", key: "briefing_time", value: store.settings?.briefingTime, fallback: "07:30")
                if store.isEnabled(.checkins) {
                    timeRow("Morning check-in", key: "checkin_morning_time", value: store.settings?.checkinMorningTime, fallback: "08:00")
                    timeRow("Evening check-in", key: "checkin_evening_time", value: store.settings?.checkinEveningTime, fallback: "21:00")
                }
            } header: { Text("Notifications") } footer: {
                Text("Alerts that fall in quiet hours arrive when they end. Non-essential notifications stay off until you turn them on.")
            }
            .listRowBackground(DS.Palette.surface)

            Section {
                if !sync.authorized {
                    Button("Connect Apple Reminders") { Task { if await sync.requestAccess() { await sync.sync() } } }
                } else {
                    ForEach(sync.lists, id: \.calendarIdentifier) { list in
                        ListSyncRow(list: list)
                    }
                    Picker("New reminders go to", selection: Binding(
                        get: { sync.defaultListId ?? "" },
                        set: { sync.defaultListId = $0.isEmpty ? nil : $0 })) {
                        Text("Default list").tag("")
                        ForEach(sync.lists, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                    if let d = sync.lastSynced {
                        LabeledContent("Last synced", value: d.formatted(date: .omitted, time: .shortened))
                    }
                }
            } header: { Text("Apple Reminders") } footer: {
                Text("Chosen lists sync both ways. If both sides change, the most recent edit wins.")
            }
            .listRowBackground(DS.Palette.surface)
            if let e = sync.lastError {
                Section { Text(e).font(DS.Typo.caption).foregroundStyle(DS.Palette.critical) }.listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Reminders")
        .onAppear { sync.refreshLists() }
    }

    /// An optional time-of-day setting stored as a Postgres `time`.
    private func timeRow(_ label: String, key: String, value: String?, fallback: String) -> some View {
        let on = Binding(get: { value != nil },
                         set: { enabled in Task { await store.updateSettings([key: enabled ? .string(fallback + ":00") : .null]) } })
        let time = Binding(
            get: { TimeOfDay.date(from: value ?? fallback) },
            set: { d in Task { await store.updateSettings([key: .string(TimeOfDay.string(from: d))]) } })
        return VStack(alignment: .leading) {
            Toggle(label, isOn: on)
            if value != nil { DatePicker(label, selection: time, displayedComponents: .hourAndMinute).labelsHidden() }
        }
    }
}

private struct ListSyncRow: View {
    @Environment(LifeStore.self) private var store
    @Environment(ReminderSync.self) private var sync
    let list: EKCalendar

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(list.title, isOn: Binding(get: { sync.isSynced(list) }, set: { sync.setList(list, synced: $0, area: sync.area(for: list)) }))
            if sync.isSynced(list) {
                Picker("Area", selection: Binding(get: { sync.area(for: list) }, set: { sync.setList(list, synced: true, area: $0) })) {
                    Text("No area").tag(UUID?.none)
                    ForEach(store.visibleAreas) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .font(DS.Typo.caption)
            }
        }
    }
}

/// "HH:mm:ss" ↔ a Date today.
enum TimeOfDay {
    static func date(from s: String) -> Date {
        let m = QuietHours.minutes(s) ?? 0
        return Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(m) * 60)
    }
    static func string(from d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d:00", c.hour ?? 0, c.minute ?? 0)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
