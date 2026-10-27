import PhotosUI
import SwiftUI
import UIKit

// MARK: - People

struct PeopleView: View {
    @Environment(AdminStore.self) private var admin
    @State private var editing: Person?
    @State private var showNew = false

    var body: some View {
        List {
            if !admin.birthdays.isEmpty {
                Section {
                    ForEach(admin.birthdays, id: \.self) { b in
                        ListRow(title: b.name, subtitle: b.turns.map { "Turns \($0)" }, symbol: "gift") {
                            RowValue(text: LifeCoding.parse(b.next)?.formatted(.dateTime.month(.abbreviated).day()) ?? b.next)
                        }
                    }
                } header: { SectionHeader(title: "Upcoming birthdays") }
                .listRowBackground(DS.Palette.surface)
            }
            let due = admin.people.filter { $0.needsContact() }
            if !due.isEmpty {
                Section {
                    ForEach(due) { p in personRow(p) }
                } header: { SectionHeader(title: "Reach out") }
                .listRowBackground(DS.Palette.surface)
            }
            Section {
                if admin.people.isEmpty {
                    EmptyState(symbol: "person.2", title: "No people yet", message: "Birthdays get a reminder the day before.", actionTitle: "Add someone") { showNew = true }
                }
                ForEach(admin.people) { p in personRow(p) }
            } header: { if !admin.people.isEmpty { SectionHeader(title: "Everyone") } }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("People")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add person") } }
        .sheet(item: $editing) { PersonEditor(person: $0) }
        .sheet(isPresented: $showNew) { PersonEditor(person: nil) }
        .refreshable { await admin.reload() }
    }

    private func personRow(_ p: Person) -> some View {
        Button { editing = p } label: {
            ListRow(title: p.name, subtitle: p.lastContacted.map { "Last contact " + $0.formatted(.relative(presentation: .named)) }, symbol: "person")
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button("Talked today", systemImage: "checkmark") { DS.Haptics.success(); Task { await admin.logContact(p) } }
                .tint(DS.Palette.positive)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await admin.delete(p) } }
        }
    }
}

private struct PersonEditor: View {
    @Environment(AdminStore.self) private var admin
    @Environment(\.dismiss) private var dismiss
    let person: Person?
    @State private var name = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var notes = ""
    @State private var gifts = ""
    @State private var keepInTouch = false
    @State private var every = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Toggle("Birthday", isOn: $hasBirthday)
                    if hasBirthday { DatePicker("Date", selection: $birthday, displayedComponents: .date) }
                }
                .listRowBackground(DS.Palette.surface)
                Section {
                    Toggle("Keep in touch", isOn: $keepInTouch)
                    if keepInTouch { Stepper("Every \(every) days", value: $every, in: 3...180, step: 1) }
                } footer: { Text("You'll get a gentle nudge when it's been longer (if nudges are on).") }
                .listRowBackground(DS.Palette.surface)
                Section("Gift ideas") {
                    TextField("Comma separated", text: $gifts, axis: .vertical)
                }
                .listRowBackground(DS.Palette.surface)
                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...6)
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle(person == nil ? "New person" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let p = person else { return }
        name = p.name
        if let b = p.birthday.flatMap(LifeCoding.parse) { hasBirthday = true; birthday = b }
        notes = p.notes ?? ""
        gifts = p.gifts.joined(separator: ", ")
        keepInTouch = p.contactEveryDays != nil
        every = p.contactEveryDays ?? 30
    }

    private func save() {
        let list = gifts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let n = name, b = hasBirthday ? birthday : nil, note = notes, e = keepInTouch ? every : nil
        Task {
            await admin.savePerson(name: n, birthday: b, notes: note, gifts: list, contactEvery: e)
            dismiss()
        }
    }
}

// MARK: - Documents

struct DocumentsView: View {
    @Environment(AdminStore.self) private var admin
    @State private var editing: LifeDocument?
    @State private var showNew = false
    @State private var opening: URL?

    var body: some View {
        List {
            if admin.documents.isEmpty {
                Section {
                    EmptyState(symbol: "doc", title: "No documents yet", message: "Note where things are and when they expire.", actionTitle: "Add") { showNew = true }
                }
                .listRowBackground(DS.Palette.surface)
            }
            let byCategory = Dictionary(grouping: admin.documents) { $0.category?.capitalizedFirst ?? "Other" }
            ForEach(byCategory.keys.sorted(), id: \.self) { cat in
                Section {
                    ForEach(byCategory[cat] ?? []) { d in docRow(d) }
                } header: { SectionHeader(title: cat) }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Documents")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add document") } }
        .sheet(item: $editing) { DocumentEditor(document: $0) }
        .sheet(isPresented: $showNew) { DocumentEditor(document: nil) }
        .refreshable { await admin.reload() }
    }

    private func docRow(_ d: LifeDocument) -> some View {
        let expires = d.expiresAt.flatMap(LifeCoding.parse)
        let soon = expires.map { $0.timeIntervalSinceNow < 30 * 86_400 } ?? false
        return Button { editing = d } label: {
            ListRow(title: d.title, subtitle: d.locationNote, symbol: d.filePath == nil ? "doc" : "doc.richtext") {
                if let expires { RowValue(text: "Expires " + expires.formatted(date: .abbreviated, time: .omitted), color: soon ? DS.Palette.warning : DS.Palette.secondary) }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { Task { await admin.delete(d) } }
        }
        .contextMenu {
            if d.filePath != nil {
                Button("Open file", systemImage: "arrow.up.forward.square") {
                    Task { if let url = await admin.fileURL(d) { _ = await UIApplication.shared.open(url) } }
                }
            }
        }
    }
}

private struct DocumentEditor: View {
    @Environment(AdminStore.self) private var admin
    @Environment(\.dismiss) private var dismiss
    let document: LifeDocument?
    @State private var title = ""
    @State private var category = ""
    @State private var location = ""
    @State private var hasExpiry = false
    @State private var expires = Date().addingTimeInterval(365 * 86_400)
    @State private var notes = ""
    @State private var item: PhotosPickerItem?
    @State private var file: Data?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title (e.g. Passport)", text: $title)
                    TextField("Category (id, insurance, car…)", text: $category).textInputAutocapitalization(.never)
                    TextField("Where is it?", text: $location)
                    Toggle("Expires", isOn: $hasExpiry)
                    if hasExpiry { DatePicker("On", selection: $expires, displayedComponents: .date) }
                } footer: { Text("A reminder comes 30 days before it expires.") }
                .listRowBackground(DS.Palette.surface)
                Section {
                    PhotosPicker(selection: $item, matching: .images) {
                        Label(file == nil ? (document?.filePath == nil ? "Attach a photo" : "Replace photo") : "Photo attached", systemImage: "paperclip")
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                } footer: { Text("Files go to your private documents bucket and open through a 10-minute link.") }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle(document == nil ? "New document" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .onAppear(perform: load)
            .onChange(of: item) { _, new in Task { await loadFile(new) } }
        }
    }

    private func load() {
        guard let d = document else { return }
        title = d.title
        category = d.category ?? ""
        location = d.locationNote ?? ""
        notes = d.notes ?? ""
        if let e = d.expiresAt.flatMap(LifeCoding.parse) { hasExpiry = true; expires = e }
    }

    private func loadFile(_ new: PhotosPickerItem?) async {
        guard let data = try? await new?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        file = img.jpegData(compressionQuality: 0.75)
    }

    private func save() {
        let t = title, c = category, l = location, e = hasExpiry ? expires : nil, n = notes, f = file
        Task {
            await admin.saveDocument(title: t, category: c, location: l, expires: e, notes: n, file: f)
            dismiss()
        }
    }
}

// MARK: - Shopping lists

struct ShoppingListView: View {
    @Environment(LifeStore.self) private var store
    let area: Area
    @State private var list = "Groceries"
    @State private var newItem = ""

    private var lists: [String] {
        Array(Set(store.items(in: area).map(Admin.list) + ["Groceries"])).sorted()
    }

    var body: some View {
        let items = store.items(in: area).filter { Admin.list(of: $0) == list }
        let open = items.filter { !$0.isDone }
        let done = items.filter(\.isDone)
        List {
            Section {
                TextField("Add to \(list)", text: $newItem)
                    .submitLabel(.done)
                    .onSubmit(add)
            }
            .listRowBackground(DS.Palette.surface)
            Section {
                ForEach(open) { item in
                    Button {
                        DS.Haptics.tap()
                        Task { await store.setDone(item, true) }
                    } label: { ListRow(title: item.title, symbol: "circle") }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(item) } }
                    }
                }
            }
            .listRowBackground(DS.Palette.surface)
            if !done.isEmpty {
                Section {
                    ForEach(done) { item in
                        Button { Task { await store.setDone(item, false) } } label: {
                            ListRow(title: item.title, symbol: "checkmark.circle.fill", accent: DS.Palette.positive, isDone: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Clear checked") { Task { for i in done { await store.delete(i) } } }
                } header: { SectionHeader(title: "In the cart") }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle(list)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("List", selection: $list) { ForEach(lists, id: \.self) { Text($0).tag($0) } }
                    Button("New list", systemImage: "plus") { list = "List \(lists.count + 1)" }
                    ShareLink(item: Admin.shareText(list: list, items: open)) { Label("Share list", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    private func add() {
        let t = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        newItem = ""
        guard !t.isEmpty else { return }
        let l = list
        Task {
            await store.perform { repo in
                let _: Item = try await repo.createItem(areaId: area.id, title: t, data: .object(["list": .string(l), "shared": .bool(true)]))
            }
            await store.reload(["items"])
        }
    }
}

// MARK: - Travel + packing

struct TravelView: View {
    @Environment(LifeStore.self) private var store
    let area: Area
    @State private var showNew = false

    var body: some View {
        let trips = store.items(in: area).filter { $0.parentId == nil }
            .sorted { ($0.data["start"]?.string ?? "") > ($1.data["start"]?.string ?? "") }
        List {
            if trips.isEmpty {
                Section { EmptyState(symbol: "airplane", title: "No trips yet", message: "Plan a trip and pack from a reusable list.", actionTitle: "New trip") { showNew = true } }
                    .listRowBackground(DS.Palette.surface)
            }
            Section {
                ForEach(trips) { t in
                    NavigationLink { TripView(area: area, trip: t) } label: {
                        let packed = store.children(of: t)
                        ListRow(title: t.title, subtitle: tripDates(t), symbol: "airplane") {
                            if !packed.isEmpty { RowValue(text: "\(packed.filter(\.isDone).count)/\(packed.count) packed") }
                        }
                    }
                }
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Travel")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New trip") } }
        .sheet(isPresented: $showNew) { NewTripSheet(area: area) }
    }

    private func tripDates(_ t: Item) -> String? {
        guard let s = t.data["start"]?.string.flatMap(LifeCoding.parse) else { return t.data["destination"]?.string }
        let e = t.data["end"]?.string.flatMap(LifeCoding.parse)
        return [s.formatted(date: .abbreviated, time: .omitted), e?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " – ")
    }
}

private struct NewTripSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let area: Area
    @State private var destination = ""
    @State private var start = Date().addingTimeInterval(7 * 86_400)
    @State private var end = Date().addingTimeInterval(10 * 86_400)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Destination", text: $destination)
                    DatePicker("From", selection: $start, displayedComponents: .date)
                    DatePicker("To", selection: $end, in: start..., displayedComponents: .date)
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("New trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let d = destination, s = start, e = end
                        Task {
                            await store.perform { repo in
                                let _: Item = try await repo.createItem(areaId: area.id, title: d, dueDate: s, data: .object([
                                    "destination": .string(d), "start": .string(LifeCoding.dayString(s)), "end": .string(LifeCoding.dayString(e)),
                                ]))
                            }
                            await store.reload(["items"])
                            dismiss()
                        }
                    }
                    .disabled(destination.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct TripView: View {
    @Environment(LifeStore.self) private var store
    let area: Area
    let trip: Item
    @State private var newThing = ""
    @State private var templateName = ""
    @State private var showSaveTemplate = false

    private var current: Area { store.area(area.id) ?? area }

    var body: some View {
        let packing = store.children(of: trip)
        List {
            Section {
                TextField("Add to packing list", text: $newThing)
                    .submitLabel(.done)
                    .onSubmit {
                        let t = newThing
                        newThing = ""
                        Task { await store.addItem(to: current, title: t, parent: trip) }
                    }
            }
            .listRowBackground(DS.Palette.surface)
            Section {
                ForEach(packing.sorted { !$0.isDone && $1.isDone }) { p in
                    Button { DS.Haptics.tap(); Task { await store.setDone(p, !p.isDone) } } label: {
                        ListRow(title: p.title, symbol: p.isDone ? "checkmark.circle.fill" : "circle",
                                accent: p.isDone ? DS.Palette.positive : DS.Palette.secondary, isDone: p.isDone)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await store.delete(p) } }
                    }
                }
            } header: {
                SectionHeader(title: packing.isEmpty ? "Packing list" : "Packing · \(packing.filter(\.isDone).count)/\(packing.count)")
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let templates = Admin.templates(current)
                    ForEach(templates.keys.sorted(), id: \.self) { name in
                        Button("Add “\(name)” list") { addTemplate(templates[name] ?? [], existing: packing) }
                    }
                    if !packing.isEmpty { Button("Save as reusable list", systemImage: "square.and.arrow.down") { showSaveTemplate = true } }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .alert("Name this packing list", isPresented: $showSaveTemplate) {
            TextField("e.g. Weekend", text: $templateName)
            Button("Save") { saveTemplate(packing.map(\.title)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func addTemplate(_ things: [String], existing: [Item]) {
        let have = Set(existing.map { $0.title.lowercased() })
        Task { for t in things where !have.contains(t.lowercased()) { await store.addItem(to: current, title: t, parent: trip) } }
    }

    private func saveTemplate(_ titles: [String]) {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var all = current.config["packing_templates"]?.object ?? [:]
        all[name] = .of(titles)
        Task { await store.updateArea(current, ["config": current.config.setting("packing_templates", .object(all))]) }
        templateName = ""
    }
}

/// Opens a life-admin area (Shopping, Travel), creating it on first use.
struct AdminAreaHost<Content: View>: View {
    @Environment(LifeStore.self) private var store
    let name: String
    let icon: String
    @ViewBuilder let content: (Area) -> Content
    @State private var area: Area?

    var body: some View {
        Group {
            if let area = store.area(area?.id) ?? area { content(area) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).dsScreen() }
        }
        .task { if area == nil { area = await store.adminArea(named: name, icon: icon) } }
    }
}
