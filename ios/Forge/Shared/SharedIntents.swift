import AppIntents
import Foundation

// Intents used by widget buttons. They're LiveActivityIntents so the system runs them in the app's
// process (which has the Supabase session); the widget's copy of perform() is never called.

/// One-tap habit check-off (Habits widget, Shortcuts).
struct LogHabitIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log habit"
    static let isDiscoverable = false

    @Parameter(title: "Habit")
    var habitId: String

    init() {}
    init(habitId: String) { self.habitId = habitId }

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        await HabitActions.log(itemId: habitId)
        #endif
        return .result()
    }
}
