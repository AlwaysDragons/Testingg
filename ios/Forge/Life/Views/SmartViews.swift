import SwiftUI

/// Search everything: items, logs, reminders, journal, captures, workouts, people, documents, subscriptions.
struct SearchView: View {
    @Environment(SmartStore.self) private var smart
    @Environment(LifeStore.self) private var store
    @Environment(ChatStore.self) private var chat
    @State private var query = ""

    var body: some View {
        List {
            if query.count < 2 {
                Section {
                    EmptyState(symbol: "magnifyingglass", title: "Search everything",
                               message: "For questions like \"when did I last deadlift 200?\", ask the assistant.",
                               actionTitle: "Ask the assistant") { chat.open() }
                }
                .listRowBackground(DS.Palette.surface)
            } else if smart.results.isEmpty && !smart.isSearching {
                Section {
                    EmptyState(symbol: "magnifyingglass", title: "No matches", actionTitle: "Ask the assistant") { chat.open(prefill: query) }
                }
                .listRowBackground(DS.Palette.surface)
            }
            let grouped = Dictionary(grouping: smart.results, by: \.type)
            ForEach(grouped.keys.sorted(), id: \.self) { type in
                Section {
                    ForEach(grouped[type] ?? [], id: \.rowId) { r in row(r) }
                } header: { SectionHeader(title: label(type)) }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search everything")
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 250_000_000)   // debounce typing
            guard !Task.isCancelled else { return }
            await smart.search(query)
        }
    }

    @ViewBuilder
    private func row(_ r: SearchResult) -> some View {
        let subtitle = [r.snippet, r.date.flatMap(LifeCoding.parse)?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · ")
        if r.type == "item", let item = store.items.first(where: { $0.id == r.id }) {
            NavigationLink { ItemDetailView(item: item) } label: { ListRow(title: r.title ?? "", subtitle: subtitle.nilIfEmpty, symbol: symbol(r.type)) }
        } else {
            ListRow(title: r.title ?? "", subtitle: subtitle.nilIfEmpty, symbol: symbol(r.type))
        }
    }

    private func label(_ type: String) -> String {
        ["item": "Items", "log": "Logs", "reminder": "Reminders", "journal": "Journal", "capture": "Captures", "workout": "Workouts",
         "exercise": "Exercises", "person": "People", "document": "Documents", "subscription": "Subscriptions"][type] ?? type.capitalizedFirst
    }

    private func symbol(_ type: String) -> String {
        ["item": "circle", "log": "text.alignleft", "reminder": "bell", "journal": "book", "capture": "tray", "workout": "dumbbell",
         "exercise": "figure.strengthtraining.traditional", "person": "person", "document": "doc", "subscription": "creditcard"][type] ?? "circle"
    }
}

/// Insights on Today: only real findings with their sample size. Swipe to dismiss.
struct InsightsSection: View {
    @Environment(SmartStore.self) private var smart

    var body: some View {
        if !smart.insights.isEmpty {
            Section {
                ForEach(smart.insights.prefix(3)) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.text).font(DS.Typo.body)
                        if let n = i.sampleSize { Text("Based on \(n) data points").font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary) }
                    }
                    .padding(.vertical, DS.Space.xs)
                    .swipeActions(edge: .trailing) {
                        Button("Dismiss", systemImage: "xmark") { Task { await smart.dismiss(i) } }
                    }
                }
            } header: { SectionHeader(title: "Insights") }
            .listRowBackground(DS.Palette.surface)
        }
    }
}
