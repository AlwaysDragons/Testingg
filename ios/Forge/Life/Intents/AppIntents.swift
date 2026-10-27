import AppIntents
import Foundation

// Siri, Shortcuts and the Action Button. These run in the app's process using the saved Supabase
// session, so they work without opening the app (except the ones that open a sheet).

/// "Ask Forge …": sends a message to the assistant and speaks/shows the reply.
struct AskAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Forge"
    static let description = IntentDescription("Ask or tell your dashboard assistant something.")

    @Parameter(title: "Message", requestValueDialog: "What should I do?")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = CloudSync().supabase else {
            return .result(dialog: "Sign in to cloud sync in Forge first.")
        }
        do {
            let reply = try await AgentClient(supabase: client).send(message)
            IntentEvents.post(.dashboardChanged)
            return .result(dialog: IntentDialog(stringLiteral: reply.reply))
        } catch {
            return .result(dialog: IntentDialog(stringLiteral: ChatStore.friendly(error)))
        }
    }
}

/// Lets intents tell a running app to refresh (e.g. after Siri added something).
enum IntentEvents {
    enum Event: String { case dashboardChanged = "forge.dashboardChanged" }
    static func post(_ e: Event) {
        NotificationCenter.default.post(name: Notification.Name(e.rawValue), object: nil)
    }
}

struct ForgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAssistantIntent(), phrases: ["Ask \(.applicationName)", "Tell \(.applicationName)"],
                    shortTitle: "Ask Forge", systemImageName: "sparkle")
    }
}
