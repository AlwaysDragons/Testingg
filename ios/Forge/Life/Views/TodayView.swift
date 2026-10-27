import SwiftUI

/// Today: what's due and what's behind across every area, plus today's reminders.
/// Later phases add calendar events (unified timeline) and the reminders view.
struct TodayView: View {
    @Environment(LifeStore.self) private var store
    @State private var editingReminder: Reminder?
    @Environment(EverydayStore.self) private var everyday
    @Environment(CalendarService.self) private var calendar
    @State private var showPlan = false
    @Environment(FocusStore.self) private var focus

    /// With Calendar on, today is one timeline of events, timed items and reminders.
    private var useTimeline: Bool { store.isEnabled(.calendar) && calendar.authorized }

    var body: some View {
        NavigationStack {
            List {
                everydaySection
                if useTimeline {
                    let entries = Timeline.build(events: calendar.today, items: store.items, reminders: store.reminders)
                    Section {
                        if entries.isEmpty { Text("Nothing scheduled today").font(DS.Typo.body).foregroundStyle(DS.Palette.secondary) }
                        ForEach(entries) { entry in
                            timelineRow(entry)
                        }
                    } header: { SectionHeader(title: "Timeline") }
                    .listRowBackground(DS.Palette.surface)
                }
                let dueReminders = useTimeline ? [] : store.reminderGroups().today
                Section {
                    ForEach(dueReminders.prefix(6)) { r in ReminderRow(reminder: r) { editingReminder = r } }
                    NavigationLink { RemindersView() } label: {
                        Text(dueReminders.isEmpty ? "Reminders" : "All reminders").font(DS.Typo.body).foregroundStyle(DS.Palette.secondary)
                    }
                } header: { if !dueReminders.isEmpty { SectionHeader(title: "Reminders") } }
                .listRowBackground(DS.Palette.surface)
                let groups = Summaries.group(store.items.filter { !$0.isDone && !$0.isHabit && $0.dueDate != nil })
                    .filter { useTimeline ? [Summaries.DueGroup.overdue, .tomorrow].contains($0.0) : [Summaries.DueGroup.overdue, .today, .tomorrow].contains($0.0) }
                if groups.isEmpty && !useTimeline {
                    Section {
                        EmptyState(symbol: "sun.max", title: "Nothing due", message: "Items with a due date show up here.")
                    }
                    .listRowBackground(DS.Palette.surface)
                }
                ForEach(groups, id: \.0) { group, items in
                    Section {
                        ForEach(items) { item in
                            NavigationLink { ItemDetailView(item: item) } label: {
                                let area = store.area(item.areaId)
                                ListRow(title: item.title, subtitle: area?.name, symbol: area?.symbol,
                                        accent: DS.Palette.area(hex: area?.color, kind: area?.kind ?? "custom")) {
                                    if let due = item.dueDate, group != .overdue {
                                        RowValue(text: due.formatted(date: .omitted, time: .shortened))
                                    }
                                }
                            }
                            .listRowBackground(DS.Palette.surface)
                            .swipeActions(edge: .leading) {
                                Button("Done", systemImage: "checkmark") {
                                    DS.Haptics.success()
                                    Task { await store.setDone(item, true) }
                                }
                                .tint(DS.Palette.positive)
                            }
                        }
                    } header: {
                        SectionHeader(title: group.rawValue)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Today")
            .refreshable { await store.reloadAll() }
            .sheet(item: $editingReminder) { ReminderEditor(reminder: $0) }
            .sheet(isPresented: $showPlan) { PlanDaySheet() }
            .toolbar {
                if useTimeline || store.isEnabled(.focus) || store.isEnabled(.nextAction) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if store.isEnabled(.nextAction) { Button("What should I do now?", systemImage: "sparkle") { focus.showNextAction = true } }
                            if store.isEnabled(.focus) {
                                Button(focus.active == nil ? "Focus" : "Focus (running)", systemImage: "timer") { focus.showSheet = true }
                            }
                            if useTimeline { Button("Plan my day", systemImage: "calendar.badge.plus") { showPlan = true } }
                        } label: { Image(systemName: "ellipsis").fontWeight(DS.symbolWeight) }
                        .accessibilityLabel("More")
                    }
                }
            }
            .onAppear { if useTimeline { calendar.reload() } }
        }
    }

    @ViewBuilder
    private func timelineRow(_ entry: TimelineEntry) -> some View {
        switch entry.kind {
        case .item(let item):
            NavigationLink { ItemDetailView(item: item) } label: { TimelineRow(entry: entry) }
                .swipeActions(edge: .leading) {
                    Button("Done", systemImage: "checkmark") { DS.Haptics.success(); Task { await store.setDone(item, true) } }
                        .tint(DS.Palette.positive)
                }
        case .reminder(let r):
            Button { editingReminder = r } label: { TimelineRow(entry: entry) }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading) {
                    Button("Done", systemImage: "checkmark") { DS.Haptics.success(); Task { await store.completeReminder(r) } }
                        .tint(DS.Palette.positive)
                }
        case .event:
            TimelineRow(entry: entry)
        }
    }

    /// Check-in, weekly review and journal, each only when switched on in Features.
    @ViewBuilder
    private var everydaySection: some View {
        let type = EverydayStore.currentType()
        let showCheckin = store.isEnabled(.checkins) && everyday.checkin(type: type) == nil
        if showCheckin || store.isEnabled(.weeklyReview) || store.isEnabled(.journal) {
            Section {
                if showCheckin {
                    Button { everyday.showCheckin = true } label: {
                        ListRow(title: type == "morning" ? "Morning check-in" : "Evening check-in", symbol: "sun.horizon")
                    }
                    .buttonStyle(.plain)
                }
                if store.isEnabled(.weeklyReview) {
                    NavigationLink { WeeklyReviewView() } label: { ListRow(title: "Weekly review", symbol: "calendar") }
                }
                if store.isEnabled(.journal) {
                    NavigationLink { JournalView() } label: { ListRow(title: "Journal", symbol: "book") }
                }
            }
            .listRowBackground(DS.Palette.surface)
        }
    }
}
