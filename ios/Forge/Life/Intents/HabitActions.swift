import Foundation
import WidgetKit

/// Habit logging that works without the UI (widget buttons, Siri): a log row with `item_id`.
@MainActor
enum HabitActions {
    static func log(itemId: String) async {
        guard let id = UUID(uuidString: itemId), let client = CloudSync().supabase else { return }
        let repo = LifeRepository(client: client)
        struct Row: Decodable { let id: UUID; let areaId: UUID; let title: String }
        guard let item: Row = (try? await repo.get("items", ["select": "id,area_id,title", "id": "eq.\(itemId.lowercased())"]) as [Row])?.first else { return }
        _ = try? await repo.addLog(areaId: item.areaId, itemId: id, note: nil, data: .object(["habit": .bool(true)]))
        // Reflect it in the widget right away; the app refreshes the full snapshot next time it runs.
        if var snap = WidgetSnapshot.load(), let i = snap.habits.firstIndex(where: { $0.id.lowercased() == itemId.lowercased() }) {
            snap.habits[i].doneToday = true
            snap.habitsLeft = max(0, snap.habitsLeft - 1)
            if snap.save() { WidgetCenter.shared.reloadAllTimelines() }
        }
        IntentEvents.post(.dashboardChanged)
    }
}
