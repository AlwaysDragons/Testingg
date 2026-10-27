import Foundation
import WidgetKit

/// Writes the widget snapshot after each reload and asks WidgetKit to refresh.
@MainActor
enum WidgetBridge {
    static func update(store: LifeStore, model: AppModel, briefing: String?) {
        let today = store.today
        let tiles = store.homeAreas.prefix(4).map { area -> WidgetSnapshot.AreaTile in
            let gym = area.kind == "gym" ? (model.analysis.workoutsThisWeek, max(1, model.trainingDays.count)) : nil
            let h = Summaries.hero(store.data(for: area, gym: gym))
            return .init(id: area.id.uuidString, name: area.name, symbol: area.symbol, accentHex: area.accentHex,
                         value: h.value, label: h.secondary ?? h.label, progress: h.progress)
        }
        let habits = store.items.filter { $0.isHabit && !$0.isDone }.prefix(6).map { item in
            WidgetSnapshot.Habit(id: item.id.uuidString, title: item.title,
                                 doneToday: Summaries.isLoggedToday(item, store.logs, now: Date(), calendar: .current))
        }
        let snapshot = WidgetSnapshot(updated: Date(), line: briefing ?? Summaries.line(today), dueToday: today.dueToday,
                                      overdue: today.overdue, remindersDue: today.remindersDue, habitsLeft: today.habitsLeft,
                                      areas: Array(tiles), habits: Array(habits), readiness: model.readiness?.score)
        guard snapshot != WidgetSnapshot.load().map({ var s = $0; s.updated = snapshot.updated; return s }) else { return }
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
