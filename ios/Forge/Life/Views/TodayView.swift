import SwiftUI

/// Today: what's due and what's behind across every area, plus today's reminders.
/// Later phases add calendar events (unified timeline) and the reminders view.
struct TodayView: View {
    @Environment(LifeStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                let groups = Summaries.group(store.items.filter { !$0.isDone && !$0.isHabit && $0.dueDate != nil })
                    .filter { [Summaries.DueGroup.overdue, .today, .tomorrow].contains($0.0) }
                if groups.isEmpty {
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
        }
    }
}
