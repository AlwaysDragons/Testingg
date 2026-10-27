import SwiftUI

/// Create or edit an area: name, kind, icon, accent, featured number.
struct AreaEditor: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let area: Area?

    @State private var name = ""
    @State private var kind = "custom"
    @State private var icon = ""
    @State private var color = AreaPalette.fallback
    @State private var heroMetric = ""
    @State private var pinned = true
    @State private var locked = false
    @State private var saving = false

    private let kinds: [(String, String)] = [("custom", "Custom"), ("tasks", "Tasks"), ("goals", "Goals"), ("habits", "Habits"),
                                             ("finance", "Finance"), ("dev", "Dev"), ("gym", "Gym")]
    private let symbols = ["square.grid.2x2", "checklist", "flag", "repeat", "creditcard", "dumbbell", "heart", "bed.double",
                           "book", "leaf", "house", "briefcase", "person.2", "airplane", "cart", "drop", "brain.head.profile",
                           "chevron.left.forwardslash.chevron.right", "music.note", "pawprint"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Kind", selection: $kind) {
                        ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("Show on Home", isOn: $pinned)
                    Toggle("Require Face ID", isOn: $locked)
                }
                .listRowBackground(DS.Palette.surface)
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: DS.Space.m) {
                        ForEach(symbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.body.weight(DS.symbolWeight))
                                .frame(width: 40, height: 40)
                                .foregroundStyle(currentIcon == s ? DS.Palette.area(hex: color) : DS.Palette.secondary)
                                .background(currentIcon == s ? DS.Palette.raised : .clear, in: Circle())
                                .onTapGesture { icon = s }
                                .accessibilityLabel(s)
                                .accessibilityAddTraits(currentIcon == s ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, DS.Space.s)
                }
                .listRowBackground(DS.Palette.surface)
                Section("Accent") {
                    HStack {
                        ForEach(AreaPalette.accents, id: \.self) { hex in
                            Circle()
                                .fill(DS.Palette.area(hex: hex))
                                .frame(width: 28, height: 28)
                                .overlay { if hex == color { Image(systemName: "checkmark").font(DS.Typo.caption).foregroundStyle(.white) } }
                                .onTapGesture { color = hex }
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel(hex)
                        }
                    }
                    .padding(.vertical, DS.Space.xs)
                }
                .listRowBackground(DS.Palette.surface)
                if let area {
                    let names = Array(Set(store.metrics(in: area).map(\.name))).sorted()
                    if !names.isEmpty {
                        Section {
                            Picker("Featured number", selection: $heroMetric) {
                                Text("Automatic").tag("")
                                ForEach(names, id: \.self) { Text(Summaries.label(forMetric: $0).capitalizedFirst).tag($0) }
                            }
                        } footer: { Text("The one number this area's card shows.") }
                        .listRowBackground(DS.Palette.surface)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle(area == nil ? "New area" : "Edit area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var currentIcon: String { icon.isEmpty ? AreaPalette.defaultSymbol(forKind: kind) : icon }

    private func load() {
        guard let a = area else { return }
        name = a.name
        kind = a.kind
        icon = a.icon ?? ""
        color = a.accentHex
        heroMetric = a.config["hero_metric"]?.string ?? ""
        pinned = a.pinned
        locked = AreaLock.isLocked(a)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = area {
            let base = heroMetric.isEmpty ? JSONValue.object(a.config.object.filter { $0.key != "hero_metric" }) : a.config.setting("hero_metric", .string(heroMetric))
            let config = base.setting("locked", .bool(locked))
            await store.updateArea(a, ["name": .string(n), "kind": .string(kind), "icon": .string(currentIcon), "color": .string(color),
                                       "pinned": .bool(pinned), "config": config])
        } else {
            let created = await store.createArea(name: n, kind: kind, icon: currentIcon, color: color)
            if let created, !pinned || locked {
                await store.updateArea(created, ["pinned": .bool(pinned), "config": created.config.setting("locked", .bool(locked))])
            }
        }
        if store.lastError == nil { dismiss() }
    }
}
