import SwiftUI

/// Morning / evening check-in: mood, energy, one line. Three taps.
struct CheckinSheet: View {
    @Environment(EverydayStore.self) private var everyday
    @Environment(\.dismiss) private var dismiss
    @State private var type = EverydayStore.currentType()
    @State private var mood: Int?
    @State private var energy: Int?
    @State private var line = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                scale("Mood", value: $mood, symbols: ["cloud.rain", "cloud", "cloud.sun", "sun.min", "sun.max"])
                scale("Energy", value: $energy, symbols: ["battery.0percent", "battery.25percent", "battery.50percent", "battery.75percent", "battery.100percent"])
                TextField(type == "morning" ? "Top priority today" : "Wins today", text: $line, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(DS.Space.m)
                    .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                Spacer()
                Button("Save") {
                    Task {
                        await everyday.submitCheckin(type: type, mood: mood, energy: energy, wins: line, notes: nil)
                        DS.Haptics.success()
                        dismiss()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(mood == nil && energy == nil && line.isEmpty)
            }
            .padding(DS.Space.m)
            .dsScreen()
            .navigationTitle(type == "morning" ? "Morning check-in" : "Evening check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $type) { Text("Morning").tag("morning"); Text("Evening").tag("evening") }
                    } label: { Image(systemName: "ellipsis") }
                }
            }
            .onAppear(perform: load)
            .onChange(of: type) { _, _ in load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        let c = everyday.checkin(type: type)
        mood = c?.mood
        energy = c?.energy
        line = c?.wins ?? ""
    }

    private func scale(_ title: String, value: Binding<Int?>, symbols: [String]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
            HStack {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        DS.Haptics.tap()
                        value.wrappedValue = n
                    } label: {
                        Image(systemName: symbols[n - 1])
                            .font(.title2.weight(DS.symbolWeight))
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .foregroundStyle(value.wrappedValue == n ? DS.Palette.primary : DS.Palette.secondary)
                            .background(value.wrappedValue == n ? DS.Palette.raised : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title) \(n) of 5")
                    .accessibilityAddTraits(value.wrappedValue == n ? .isSelected : [])
                }
            }
        }
    }
}

/// The week in review: summary, wins, misses, focus, and one-tap suggestions.
struct WeeklyReviewView: View {
    @Environment(EverydayStore.self) private var everyday
    @Environment(LifeStore.self) private var store
    @State private var added: Set<WeeklyReview.Suggestion> = []

    var body: some View {
        List {
            if let r = everyday.review {
                Section { Text(r.summary).font(DS.Typo.body) }
                    .listRowBackground(DS.Palette.surface)
                if !r.wins.isEmpty {
                    Section {
                        ForEach(r.wins, id: \.self) { ListRow(title: $0, symbol: "checkmark", accent: DS.Palette.positive) }
                    } header: { SectionHeader(title: "Wins") }
                    .listRowBackground(DS.Palette.surface)
                }
                if !r.misses.isEmpty {
                    Section {
                        ForEach(r.misses, id: \.self) { ListRow(title: $0, symbol: "circle.dashed") }
                    } header: { SectionHeader(title: "Missed") }
                    .listRowBackground(DS.Palette.surface)
                }
                if !r.focus.isEmpty {
                    Section {
                        Text(r.focus).font(DS.Typo.body)
                    } header: { SectionHeader(title: "Next week's focus") }
                    .listRowBackground(DS.Palette.surface)
                }
                if !r.suggestions.isEmpty {
                    Section {
                        ForEach(r.suggestions, id: \.self) { s in
                            Button { accept(s) } label: {
                                ListRow(title: s.title, subtitle: s.area, symbol: added.contains(s) ? "checkmark.circle.fill" : "plus.circle",
                                        accent: added.contains(s) ? DS.Palette.positive : DS.Palette.accent)
                            }
                            .buttonStyle(.plain)
                            .disabled(added.contains(s))
                        }
                        if added.count < r.suggestions.count {
                            Button("Add all") { r.suggestions.forEach(accept) }
                        }
                    } header: { SectionHeader(title: "Suggestions") }
                    .listRowBackground(DS.Palette.surface)
                }
            } else {
                Section {
                    EmptyState(symbol: "calendar", title: "This week's review", message: "A summary of wins, misses and streaks per area.",
                               actionTitle: everyday.isGenerating ? nil : "Write it") { Task { await everyday.generateReview() } }
                    if everyday.isGenerating { ProgressView().frame(maxWidth: .infinity) }
                }
                .listRowBackground(DS.Palette.surface)
            }
            if let e = everyday.lastError {
                Section { Text(e).font(DS.Typo.caption).foregroundStyle(DS.Palette.critical) }.listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Weekly review")
        .toolbar {
            if everyday.review != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await everyday.generateReview() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(everyday.isGenerating)
                        .accessibilityLabel("Rewrite")
                }
            }
        }
    }

    /// Adds a suggestion as an item due next Monday in its area (or the first area if it no longer exists).
    private func accept(_ s: WeeklyReview.Suggestion) {
        guard !added.contains(s), let area = store.area(named: s.area) ?? store.visibleAreas.first else { return }
        added.insert(s)
        let monday = Calendar.current.date(byAdding: .day, value: 7, to: EverydayStore.weekStart())?.addingTimeInterval(9 * 3600)
        Task { await store.addItem(to: area, title: s.title, due: monday) }
    }
}

/// Daily journal, written from the day's logs, check-ins, workouts and completed items. Editable.
struct JournalView: View {
    @Environment(EverydayStore.self) private var everyday
    @State private var editing: Date?

    var body: some View {
        List {
            Section {
                let today = everyday.entry(for: Date())
                if let today {
                    Text(today.content).font(DS.Typo.body).onTapGesture { editing = Date() }
                } else {
                    Button(everyday.isGenerating ? "Writing…" : "Write today's entry") { Task { await everyday.generateJournal(for: Date()) } }
                        .disabled(everyday.isGenerating)
                }
            } header: { SectionHeader(title: "Today") }
            .listRowBackground(DS.Palette.surface)
            let past = everyday.journal.filter { $0.date != LifeCoding.dayString(Date()) }
            if !past.isEmpty {
                Section {
                    ForEach(past) { e in
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text(LifeCoding.parse(e.date)?.formatted(date: .complete, time: .omitted) ?? e.date)
                                .font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                            Text(e.content).font(DS.Typo.body).lineLimit(4)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = LifeCoding.parse(e.date) }
                    }
                } header: { SectionHeader(title: "Earlier") }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Journal")
        .task { await everyday.backfillYesterday() }
        .sheet(item: Binding(get: { editing.map(IdentifiedDate.init) }, set: { editing = $0?.date })) { d in
            JournalEditor(day: d.date)
        }
    }
}

private struct IdentifiedDate: Identifiable {
    let date: Date
    var id: String { LifeCoding.dayString(date) }
}

private struct JournalEditor: View {
    @Environment(EverydayStore.self) private var everyday
    @Environment(\.dismiss) private var dismiss
    let day: Date
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(DS.Typo.body)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.m)
                .dsScreen()
                .navigationTitle(day.formatted(date: .abbreviated, time: .omitted))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await everyday.saveJournal(text, for: day); dismiss() } }
                    }
                }
                .onAppear { text = everyday.entry(for: day)?.content ?? "" }
        }
    }
}
