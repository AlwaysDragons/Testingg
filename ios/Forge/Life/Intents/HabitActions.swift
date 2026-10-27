import Foundation
import WidgetKit

/// Habit logging that works without the UI (widget buttons, Siri): a log row with `item_id`.
@MainActor
enum HabitActions {
    static func log(itemId: String) async {
        guard let id = UUID(uuidString: itemId), let client = CloudSync().supabase else { return }
        // Same rule as the app: one completion per habit per day (ai_log_habit is idempotent).
        let _: JSONValue? = try? await LifeRepository(client: client).rpc("ai_log_habit", ["p_item_id": .of(id)])
        // Reflect it in the widget right away; the app refreshes the full snapshot next time it runs.
        if var snap = WidgetSnapshot.load(), let i = snap.habits.firstIndex(where: { $0.id.lowercased() == itemId.lowercased() }) {
            snap.habits[i].doneToday = true
            snap.habitsLeft = max(0, snap.habitsLeft - 1)
            if snap.save() { WidgetCenter.shared.reloadAllTimelines() }
        }
        IntentEvents.post(.dashboardChanged)
    }
}
