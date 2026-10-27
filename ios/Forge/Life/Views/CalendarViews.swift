import EventKit
import SwiftUI

/// One row of the unified timeline: time on the left, one line of content.
struct TimelineRow: View {
    @Environment(LifeStore.self) private var store
    let entry: TimelineEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
            Text(entry.time.map { $0.formatted(date: .omitted, time: .shortened) } ?? "All day")
                .font(DS.Typo.caption).monospacedDigit()
                .foregroundStyle(DS.Palette.secondary)
                .frame(width: 64, alignment: .leading)
            switch entry.kind {
            case .event(let e):
                ListRow(title: e.title, subtitle: duration(e) ?? e.calendarTitle, symbol: "calendar")
            case .item(let i):
                let area = store.area(i.areaId)
                ListRow(title: i.title, subtitle: area?.name, symbol: "circle", accent: DS.Palette.area(hex: area?.color, kind: area?.kind ?? "custom"))
            case .reminder(let r):
                ListRow(title: r.title, subtitle: store.area(r.areaId)?.name, symbol: "bell")
            }
        }
    }

    private func duration(_ e: CalEvent) -> String? {
        guard !e.isAllDay else { return nil }
        let m = Int(e.end.timeIntervalSince(e.start) / 60)
        return m >= 60 ? "\(m / 60) h\(m % 60 == 0 ? "" : " \(m % 60) min") · \(e.calendarTitle)" : "\(m) min · \(e.calendarTitle)"
    }
}

/// "Plan my day": the AI drafts time blocks in your free slots; nothing is written until you approve.
struct PlanDaySheet: View {
    @Environment(CalendarService.self) private var calendar
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var plan: DayPlan?
    @State private var selected: Set<DayPlan.Block> = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    Section { ProgressView("Drafting your day").frame(maxWidth: .infinity) }.listRowBackground(DS.Palette.surface)
                } else if let plan {
                    if let note = plan.note { Section { Text(note).font(DS.Typo.body) }.listRowBackground(DS.Palette.surface) }
                    Section {
                        ForEach(plan.blocks, id: \.self) { b in
                            Button {
                                if selected.contains(b) { selected.remove(b) } else { selected.insert(b) }
                            } label: {
                                ListRow(title: b.title, subtitle: range(b), symbol: selected.contains(b) ? "checkmark.circle.fill" : "circle",
                                        accent: selected.contains(b) ? DS.Palette.accent : DS.Palette.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    } footer: { Text("Choose the blocks to add to your calendar.") }
                    .listRowBackground(DS.Palette.surface)
                } else if let error {
                    Section { Text(error).foregroundStyle(DS.Palette.critical) }.listRowBackground(DS.Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Plan my day")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if plan != nil {
                    Button("Add \(selected.count) to calendar") {
                        calendar.add(blocks: plan?.blocks.filter(selected.contains) ?? [])
                        DS.Haptics.success()
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selected.isEmpty)
                    .padding(DS.Space.m)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await draft() }
        }
    }

    private func draft() async {
        guard let client = cloud.supabase else { error = "Sign in first."; return }
        loading = true
        defer { loading = false }
        do {
            let r = try await AgentClient(supabase: client)
                .task("plan_day", params: ["device_context": .string(Timeline.context(events: calendar.today))], as: DayPlan.self)
            plan = r.result
            selected = Set(r.result.blocks)
        } catch {
            self.error = ChatStore.friendly(error)
        }
    }

    private func range(_ b: DayPlan.Block) -> String {
        guard let s = LifeCoding.parse(b.start), let e = LifeCoding.parse(b.end) else { return "" }
        return "\(s.formatted(date: .omitted, time: .shortened)) – \(e.formatted(date: .omitted, time: .shortened))"
    }
}

/// Settings → Calendar: access, which calendars show on Today, where planned blocks go.
struct CalendarSettingsView: View {
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        Form {
            if !calendar.authorized {
                Section {
                    Button("Connect Calendar") { Task { await calendar.requestAccess() } }
                } footer: { Text("Events stay on this device; only a short summary of today is sent to the assistant when you ask it to plan.") }
                .listRowBackground(DS.Palette.surface)
            } else {
                Section("Show on Today") {
                    ForEach(calendar.calendars, id: \.calendarIdentifier) { c in
                        Toggle(c.title, isOn: Binding(get: { calendar.isShown(c) }, set: { calendar.setShown(c, $0) }))
                    }
                }
                .listRowBackground(DS.Palette.surface)
                Section {
                    Picker("Planned blocks go to", selection: Binding(get: { calendar.blockCalendarId ?? "" }, set: { calendar.blockCalendarId = $0.isEmpty ? nil : $0 })) {
                        Text("Default calendar").tag("")
                        ForEach(calendar.writableCalendars, id: \.calendarIdentifier) { Text($0.title).tag($0.calendarIdentifier) }
                    }
                }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Calendar")
    }
}
