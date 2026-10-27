import SwiftUI
import Charts

/// Deep view of one area: hero stat + Overview | Items | Logs | Charts.
struct AreaDetailView: View {
    @Environment(LifeStore.self) private var store
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatStore.self) private var chat
    @Environment(AreaLock.self) private var areaLock
    let area: Area

    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", items = "Items", logs = "Logs", charts = "Charts"; var id: String { rawValue } }
    @State private var tab: Tab = .overview
    @State private var showEditor = false
    @State private var showLegacy = false
    @State private var newItem = ""
    @State private var newLog = ""
    @State private var search = ""
    @State private var statusFilter: String?
    @State private var tagFilter: String?
    @State private var priorityFilter: Int?
    @State private var confirmDelete = false

    private var current: Area { store.area(area.id) ?? area }
    private var accent: Color { DS.Palette.area(hex: current.color, kind: current.kind) }

    var body: some View {
        if areaLock.isOpen(current) {
            content
        } else {
            EmptyState(symbol: "lock", title: "\(current.name) is locked", actionTitle: "Unlock") { Task { _ = await areaLock.unlock(current) } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsScreen()
                .navigationTitle(current.name)
                .navigationBarTitleDisplayMode(.inline)
                .task { _ = await areaLock.unlock(current) }
        }
    }

    private var content: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    let h = hero
                    StatView(value: h.value, label: h.label, secondary: h.secondary)
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: DS.Space.s, leading: DS.Space.xs, bottom: DS.Space.s, trailing: DS.Space.xs))
            }
            switch tab {
            case .overview: overview
            case .items: itemsSection
            case .logs: logsSection
            case .charts: chartsSection
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search \(current.name)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Ask about this", systemImage: "sparkle") { chat.open(prefill: "About my \(current.name) area: ") }
                    Button("Edit area", systemImage: "pencil") { showEditor = true }
                    Button(current.pinned ? "Unpin from Home" : "Pin to Home", systemImage: current.pinned ? "pin.slash" : "pin") {
                        Task { await store.updateArea(current, ["pinned": .bool(!current.pinned)]) }
                    }
                    if tab == .items { filterMenu }
                    Button("Delete area", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").fontWeight(DS.symbolWeight)
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showEditor) { AreaEditor(area: current) }
        .sheet(isPresented: $showLegacy) { LegacyForgeView() }
        .confirmationDialog("Delete \(current.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete area and its items", role: .destructive) {
                Task { await store.deleteArea(current); dismiss() }
            }
        } message: {
            Text("Items, logs and metrics in this area are deleted. Workouts and reminders are kept.")
        }
    }

    private var hero: Summaries.Hero {
        let gym = current.kind == "gym" ? (model.analysis.workoutsThisWeek, max(1, model.trainingDays.count)) : nil
        return Summaries.hero(store.data(for: current, gym: gym, readiness: current.kind == "gym" ? model.readiness?.score : nil))
    }

    // MARK: Overview

    @ViewBuilder
    private var overview: some View {
        HabitsSection(area: current)
        if current.config["targets"] != nil { NutritionSection(area: current) }
        if current.kind == "finance" { MoneySection(area: current) }
        if current.kind == "gym" { gymOverview }
        let upcoming = store.items(in: current).filter { !$0.isDone && !$0.isHabit && !Savings.isGoal($0) }.prefix(3)
        if !upcoming.isEmpty {
            Section {
                ForEach(Array(upcoming)) { item in itemRow(item) }
            } header: { SectionHeader(title: "Next up") }
        }
        let reminders = store.reminders(in: current).filter { !$0.isDone }
        if !reminders.isEmpty {
            Section {
                ForEach(reminders.prefix(5)) { r in
                    ListRow(title: r.title, subtitle: r.remindAt.map { $0.formatted(date: .abbreviated, time: .shortened) }, symbol: "bell")
                }
            } header: { SectionHeader(title: "Reminders") }
            .listRowBackground(DS.Palette.surface)
        }
        let recentLogs = store.logs(in: current).prefix(3)
        if !recentLogs.isEmpty {
            Section {
                ForEach(Array(recentLogs)) { log in logRow(log) }
            } header: { SectionHeader(title: "Recent") }
            .listRowBackground(DS.Palette.surface)
        }
        if current.kind != "gym", upcoming.isEmpty, reminders.isEmpty, recentLogs.isEmpty, store.metrics(in: current).isEmpty {
            Section {
                EmptyState(symbol: current.symbol, title: "Nothing here yet", message: "Add an item, or ask the assistant to track something.",
                           actionTitle: "Add item") { tab = .items }
            }
            .listRowBackground(DS.Palette.surface)
        }
    }

    @ViewBuilder
    private var gymOverview: some View {
        Section {
            Button { showLegacy = true } label: {
                ListRow(title: "Open training", subtitle: "Today, training, recovery and coach", symbol: "dumbbell", accent: accent) {
                    Image(systemName: "chevron.up").font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(DS.Palette.surface)
        RecoverySection(accent: accent)
        let weeks = model.analysis.weeks.suffix(8)
        if weeks.count > 1 {
            Section {
                Chart(Array(weeks)) { w in
                    BarMark(x: .value("Week", w.weekStart, unit: .weekOfYear), y: .value("Volume", Fmt.weightValue(w.tonnageKg, lbs: model.useLbs)))
                        .foregroundStyle(accent)
                        .cornerRadius(4)
                }
                .chartYAxis(.hidden)
                .frame(height: 120)
            } header: { SectionHeader(title: "Weekly volume") }
            .listRowBackground(DS.Palette.surface)
        }
        let prs = model.analysis.recentPRs.prefix(3)
        if !prs.isEmpty {
            Section {
                ForEach(Array(prs)) { pr in
                    ListRow(title: pr.title, subtitle: pr.date.formatted(date: .abbreviated, time: .omitted), symbol: "trophy") {
                        RowValue(text: Fmt.weight(pr.e1rm, lbs: model.useLbs), color: accent)
                    }
                }
            } header: { SectionHeader(title: "Recent PRs") }
            .listRowBackground(DS.Palette.surface)
        }
        let recent = model.workouts.sorted { $0.startTime > $1.startTime }.prefix(3)
        if !recent.isEmpty {
            Section {
                ForEach(Array(recent)) { w in
                    ListRow(title: w.title, subtitle: w.startTime.formatted(date: .abbreviated, time: .omitted), symbol: "figure.strengthtraining.traditional") {
                        RowValue(text: "\(w.workingSetCount) sets")
                    }
                }
            } header: { SectionHeader(title: "Recent workouts") }
            .listRowBackground(DS.Palette.surface)
        }
    }

    // MARK: Items

    private var filteredItems: [Item] {
        store.items(in: current).filter { item in
            (statusFilter == nil || item.status == statusFilter) &&
            (tagFilter == nil || item.tags.contains(tagFilter!)) &&
            (priorityFilter == nil || item.priority == priorityFilter) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.tags.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    @ViewBuilder
    private var itemsSection: some View {
        Section {
            TextField("Add item", text: $newItem)
                .submitLabel(.done)
                .onSubmit {
                    let title = newItem
                    newItem = ""
                    Task { await store.addItem(to: current, title: title) }
                }
        }
        .listRowBackground(DS.Palette.surface)
        let groups = Summaries.group(filteredItems)
        if groups.isEmpty {
            Section { EmptyState(symbol: "checklist", title: search.isEmpty ? "No items" : "No matches") }
                .listRowBackground(DS.Palette.surface)
        }
        ForEach(groups, id: \.0) { group, items in
            Section {
                ForEach(items) { item in itemRow(item) }
            } header: { SectionHeader(title: group.rawValue) }
        }
    }

    @ViewBuilder
    private var filterMenu: some View {
        Menu("Filter", systemImage: "line.3.horizontal.decrease") {
            Picker("Status", selection: $statusFilter) {
                Text("Any status").tag(String?.none)
                ForEach(ItemStatus.all, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
            }
            Picker("Priority", selection: $priorityFilter) {
                Text("Any priority").tag(Int?.none)
                ForEach(ItemStatus.priorities, id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
            }
            let tags = Array(Set(store.items(in: current).flatMap(\.tags))).sorted()
            if !tags.isEmpty {
                Picker("Tag", selection: $tagFilter) {
                    Text("Any tag").tag(String?.none)
                    ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
        }
    }

    private func itemRow(_ item: Item) -> some View {
        NavigationLink {
            ItemDetailView(item: item)
        } label: {
            ListRow(title: item.title, subtitle: subtitle(item), symbol: item.isDone ? "checkmark.circle.fill" : "circle",
                    accent: item.isDone ? accent : DS.Palette.secondary, isDone: item.isDone) {
                if item.progress > 0, !item.isDone { ProgressRing(progress: Double(item.progress) / 100, accent: accent, lineWidth: 3, size: 20) }
            }
        }
        .listRowBackground(DS.Palette.surface)
        .swipeActions(edge: .leading) {
            Button(item.isDone ? "Reopen" : "Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                if !item.isDone { DS.Haptics.success() }
                Task { await store.setDone(item, !item.isDone) }
            }
            .tint(accent)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
        }
    }

    private func subtitle(_ item: Item) -> String? {
        var parts: [String] = []
        if let due = item.dueDate { parts.append(due.formatted(.relative(presentation: .named))) }
        if item.priority > 0 { parts.append(ItemStatus.priorities[item.priority].1) }
        if !item.tags.isEmpty { parts.append(item.tags.joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Logs

    @ViewBuilder
    private var logsSection: some View {
        Section {
            TextField("Add a note", text: $newLog, axis: .vertical)
                .submitLabel(.done)
                .onSubmit {
                    let note = newLog.trimmingCharacters(in: .whitespacesAndNewlines)
                    newLog = ""
                    guard !note.isEmpty else { return }
                    Task { await store.addLog(to: current, note: note) }
                }
        }
        .listRowBackground(DS.Palette.surface)
        let logs = store.logs(in: current).filter { search.isEmpty || ($0.note ?? "").localizedCaseInsensitiveContains(search) }
        if logs.isEmpty {
            Section { EmptyState(symbol: "text.alignleft", title: search.isEmpty ? "No logs yet" : "No matches") }
                .listRowBackground(DS.Palette.surface)
        } else {
            let byDay = Dictionary(grouping: logs) { Calendar.current.startOfDay(for: $0.loggedAt) }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                Section {
                    ForEach(byDay[day] ?? []) { log in logRow(log) }
                } header: { SectionHeader(title: day.formatted(date: .abbreviated, time: .omitted)) }
                .listRowBackground(DS.Palette.surface)
            }
        }
    }

    private func logRow(_ log: LogEntry) -> some View {
        let itemTitle = log.itemId.flatMap { id in store.items.first { $0.id == id }?.title }
        return ListRow(title: log.note ?? itemTitle ?? "Logged", subtitle: [itemTitle, log.loggedAt.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await store.perform { try await $0.deleteLog(log.id) }; await store.reload(["logs"]) }
                }
            }
    }

    // MARK: Charts

    @ViewBuilder
    private var chartsSection: some View {
        let names = Array(Set(store.metrics(in: current).map(\.name))).sorted()
        if names.isEmpty {
            Section { EmptyState(symbol: "chart.xyaxis.line", title: "No metrics yet", message: "Numbers you record here show up as charts.") }
                .listRowBackground(DS.Palette.surface)
        } else {
            ForEach(names, id: \.self) { name in
                Section {
                    MetricChart(metrics: store.metrics(in: current).filter { $0.name == name }, accent: accent)
                } header: { SectionHeader(title: Summaries.label(forMetric: name).capitalizedFirst) }
                .listRowBackground(DS.Palette.surface)
            }
        }
    }
}

/// Single-series chart with a range picker and tap-to-inspect.
struct MetricChart: View {
    let metrics: [Metric]
    var accent: Color = DS.Palette.accent

    enum Range: String, CaseIterable, Identifiable {
        case week = "7D", month = "30D", quarter = "90D", year = "1Y"
        var id: String { rawValue }
        var days: Double { switch self { case .week: return 7; case .month: return 30; case .quarter: return 90; case .year: return 365 } }
    }
    @State private var range: Range = .month
    @State private var selected: Date?

    private var points: [Metric] {
        let cutoff = Date().addingTimeInterval(-range.days * 86_400)
        return metrics.filter { $0.recordedAt >= cutoff }.sorted { $0.recordedAt < $1.recordedAt }
    }

    private var selectedPoint: Metric? {
        guard let selected else { return nil }
        return points.min { abs($0.recordedAt.timeIntervalSince(selected)) < abs($1.recordedAt.timeIntervalSince(selected)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                if let p = selectedPoint ?? points.last {
                    Text(Summaries.number(p.value) + (p.unit.map { Summaries.unitSuffix($0) } ?? ""))
                        .font(DS.Typo.bodyEmphasis).monospacedDigit()
                    Text(p.recordedAt.formatted(date: .abbreviated, time: .omitted)).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                }
                Spacer()
            }
            if points.isEmpty {
                Text("No data in this range").font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).frame(height: 140)
            } else {
                Chart(points) { m in
                    LineMark(x: .value("Date", m.recordedAt), y: .value("Value", m.value))
                        .foregroundStyle(accent)
                        .interpolationMethod(.monotone)
                    if let s = selectedPoint, s.id == m.id {
                        PointMark(x: .value("Date", m.recordedAt), y: .value("Value", m.value)).foregroundStyle(accent)
                    }
                }
                .chartXSelection(value: $selected)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.Palette.secondary.opacity(0.15)); AxisValueLabel() } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel() } }
                .frame(height: 140)
            }
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, DS.Space.s)
    }
}

/// Labels for item status and priority.
enum ItemStatus {
    static let all: [(String, String)] = [("not_started", "Not started"), ("in_progress", "In progress"), ("blocked", "Blocked"), ("done", "Done")]
    static let priorities: [(Int, String)] = [(0, "No priority"), (1, "Low"), (2, "Medium"), (3, "High")]
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
