import SwiftUI

/// Habits in an area: one tap to check off, streak on the right.
struct HabitsSection: View {
    @Environment(LifeStore.self) private var store
    @Environment(HabitsStore.self) private var habits
    let area: Area

    var body: some View {
        let list = store.items(in: area).filter { $0.isHabit && !$0.isDone }
        if !list.isEmpty {
            Section {
                ForEach(list) { item in
                    let done = habits.streaks[item.id]?.doneToday ?? Summaries.isLoggedToday(item, store.logs, now: Date(), calendar: .current)
                    Button {
                        guard !done else { return }
                        DS.Haptics.success()
                        Task { await habits.log(item, store: store) }
                    } label: {
                        ListRow(title: item.title, symbol: done ? "checkmark.circle.fill" : "circle",
                                accent: done ? DS.Palette.area(hex: area.color, kind: area.kind) : DS.Palette.secondary) {
                            if let s = habits.streaks[item.id], s.current > 0 {
                                RowValue(text: s.current == 1 ? "1 day" : "\(s.current) days")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(done ? "Done today" : "Mark done today")
                }
            } header: { SectionHeader(title: "Habits today") }
            .listRowBackground(DS.Palette.surface)
        }
    }
}

/// Focus timer: pick an area and a length, then a calm countdown. Logs minutes to the area.
struct FocusSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(FocusStore.self) private var focus
    @Environment(\.dismiss) private var dismiss
    @State private var areaId: UUID?
    @State private var minutes = 25
    private let lengths = [15, 25, 45, 60]

    var body: some View {
        NavigationStack {
            VStack(spacing: DS.Space.l) {
                if let s = focus.active {
                    Spacer()
                    Text(s.areaName).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                    Text(timerInterval: Date()...max(Date(), s.endsAt), countsDown: true)
                        .font(.system(size: 64, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Button("End session") { Task { await focus.end(store: store); DS.Haptics.success() } }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Picker("Area", selection: $areaId) {
                        ForEach(store.visibleAreas) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .pickerStyle(.menu)
                    Picker("Length", selection: $minutes) {
                        ForEach(lengths, id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if !focus.totals.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text("Last 7 days").font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                            ForEach(focus.totals, id: \.self) { t in
                                HStack { Text(t.area); Spacer(); Text(hours(t.minutes)).foregroundStyle(DS.Palette.secondary).monospacedDigit() }
                                    .font(DS.Typo.body)
                            }
                        }
                        .dsCard()
                    }
                    Spacer()
                    Button("Start") {
                        guard let area = store.area(areaId) else { return }
                        Task { await focus.start(area: area, minutes: minutes, store: store) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.area(areaId) == nil)
                }
            }
            .padding(DS.Space.m)
            .dsScreen()
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { if areaId == nil { areaId = store.homeAreas.first?.id ?? store.visibleAreas.first?.id } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hours(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }
}

/// One next action plus two alternates, from your calendar gaps, energy and what's due.
struct NextActionSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(FocusStore.self) private var focus
    @Environment(CalendarService.self) private var calendar
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var result: NextAction?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let r = result {
                    Section {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Text(r.action.title).font(DS.Typo.title)
                            Text(r.why).font(DS.Typo.body).foregroundStyle(DS.Palette.secondary)
                        }
                        .padding(.vertical, DS.Space.s)
                        actions(for: r.action)
                    }
                    .listRowBackground(DS.Palette.surface)
                    if !r.alternates.isEmpty {
                        Section {
                            ForEach(r.alternates, id: \.self) { o in
                                ListRow(title: o.title, subtitle: [o.area, o.minutes.map { "\($0) min" }].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                            }
                        } header: { SectionHeader(title: "Or") }
                        .listRowBackground(DS.Palette.surface)
                    }
                } else if let error {
                    Section { Text(error).foregroundStyle(DS.Palette.critical) }.listRowBackground(DS.Palette.surface)
                } else {
                    Section { ProgressView("Thinking").frame(maxWidth: .infinity) }.listRowBackground(DS.Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("What now?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func actions(for o: NextAction.Option) -> some View {
        if let minutes = o.minutes, let area = o.area.flatMap(store.area(named:)) ?? o.itemId.flatMap({ id in store.items.first { $0.id == id } }).flatMap({ store.area($0.areaId) }) {
            Button("Start \(minutes) min focus") {
                Task { await focus.start(area: area, minutes: minutes, store: store); dismiss() }
            }
        }
        if let id = o.itemId, let item = store.items.first(where: { $0.id == id }) {
            Button("Mark done") { Task { await store.setDone(item, true); DS.Haptics.success(); dismiss() } }
        }
    }

    private func load() async {
        guard let client = cloud.supabase else { error = "Sign in first."; return }
        var params: [String: JSONValue] = [:]
        if store.isEnabled(.calendar), calendar.authorized { params["device_context"] = .string(Timeline.context(events: calendar.today)) }
        do {
            result = try await AgentClient(supabase: client).task("next_action", params: params, as: NextAction.self).result
        } catch {
            self.error = ChatStore.friendly(error)
        }
    }
}
