import SwiftUI

/// Full detail for one item: edit fields, milestones (children) and its history.
struct ItemDetailView: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: Item

    @State private var title = ""
    @State private var status = "not_started"
    @State private var progress = 0.0
    @State private var priority = 0
    @State private var hasDue = false
    @State private var due = Date()
    @State private var tags = ""
    @State private var repeats = false
    @State private var newMilestone = ""
    @State private var loaded = false

    private var current: Item { store.items.first { $0.id == item.id } ?? item }
    private var area: Area? { store.area(item.areaId) }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $title, axis: .vertical)
                Picker("Status", selection: $status) {
                    ForEach(ItemStatus.all, id: \.0) { Text($0.1).tag($0.0) }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Progress")
                        Spacer()
                        Text("\(Int(progress))%").foregroundStyle(DS.Palette.secondary).monospacedDigit()
                    }
                    Slider(value: $progress, in: 0...100, step: 5)
                        .disabled(!store.children(of: current).isEmpty)  // rolled up from milestones
                }
                Picker("Priority", selection: $priority) {
                    ForEach(ItemStatus.priorities, id: \.0) { Text($0.1).tag($0.0) }
                }
            }
            .listRowBackground(DS.Palette.surface)
            Section {
                Toggle("Due date", isOn: $hasDue)
                if hasDue { DatePicker("Due", selection: $due) }
                Toggle("Repeats daily (habit)", isOn: $repeats)
                TextField("Tags, comma separated", text: $tags)
                    .textInputAutocapitalization(.never)
            }
            .listRowBackground(DS.Palette.surface)

            let children = store.children(of: current)
            Section {
                ForEach(children) { child in
                    Button {
                        Task { await store.setDone(child, !child.isDone) }
                    } label: {
                        ListRow(title: child.title, symbol: child.isDone ? "checkmark.circle.fill" : "circle",
                                accent: DS.Palette.area(hex: area?.color, kind: area?.kind ?? "custom"), isDone: child.isDone)
                    }
                    .buttonStyle(.plain)
                }
                TextField("Add milestone", text: $newMilestone)
                    .onSubmit {
                        let t = newMilestone
                        newMilestone = ""
                        if let area { Task { await store.addItem(to: area, title: t, parent: current) } }
                    }
            } header: {
                Text("Milestones")
            } footer: {
                if !children.isEmpty { Text("Progress rolls up from milestones.") }
            }
            .listRowBackground(DS.Palette.surface)

            let history = store.logs.filter { $0.itemId == item.id }
            if !history.isEmpty {
                Section("History") {
                    ForEach(history.prefix(30)) { log in
                        ListRow(title: log.note ?? "Done", subtitle: log.loggedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .listRowBackground(DS.Palette.surface)
            }

            Section {
                Button("Delete item", role: .destructive) {
                    Task { await store.delete(current); dismiss() }
                }
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle(area?.name ?? "Item")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let i = current
        title = i.title
        status = i.status
        progress = Double(i.progress)
        priority = i.priority
        hasDue = i.dueDate != nil
        due = i.dueDate ?? Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 9 * 3600)
        tags = i.tags.joined(separator: ", ")
        repeats = i.isHabit
    }

    /// Saves only what changed when leaving the screen.
    private func save() {
        let i = current
        var fields: Row = [:]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, t != i.title { fields["title"] = .string(t) }
        if status != i.status {
            fields["status"] = .string(status)
            fields["completed_at"] = status == "done" ? .of(Date()) : .null
            if status == "done" { fields["progress"] = .int(100) }
        }
        if Int(progress) != i.progress, fields["progress"] == nil { fields["progress"] = .int(Int(progress)) }
        if priority != i.priority { fields["priority"] = .int(priority) }
        let newDue: Date? = hasDue ? due : nil
        if newDue != i.dueDate { fields["due_date"] = .of(newDue) }
        let tagList = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if tagList != i.tags { fields["tags"] = .of(tagList) }
        if repeats != i.isHabit { fields["recurrence"] = repeats ? .string("FREQ=DAILY") : .null }
        guard !fields.isEmpty else { return }
        Task { await store.update(i, fields) }
    }
}
