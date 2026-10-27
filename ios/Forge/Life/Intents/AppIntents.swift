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

/// "Capture in Forge": save a thought and let the assistant sort it, without opening the app.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture"
    static let description = IntentDescription("Save a thought; Forge sorts it into the right area.")

    @Parameter(title: "Text", requestValueDialog: "What do you want to capture?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let client = CloudSync().supabase else { return .result(dialog: "Sign in to cloud sync in Forge first.") }
        guard let saved = await CaptureStore.capture(text, source: "siri", client: client) else {
            return .result(dialog: "Couldn't save that. Try again.")
        }
        let outcome = saved.1
        IntentEvents.post(.dashboardChanged)
        return .result(dialog: IntentDialog(stringLiteral: outcome.map { $0.sorted ? "Sorted: \($0.summary)" : "Saved to your inbox." } ?? "Saved to your inbox."))
    }
}

/// Opens the capture sheet (good for the Action Button).
struct OpenCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Open quick capture"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentEvents.pendingCapture = true   // picked up when the UI appears (cold launch)
        IntentEvents.post(.openCapture)
        return .result()
    }
}

/// Lets intents tell a running app to refresh (e.g. after Siri added something).
@MainActor
enum IntentEvents {
    static var pendingCapture = false
    enum Event: String { case dashboardChanged = "forge.dashboardChanged", openCapture = "forge.openCapture" }
    static func post(_ e: Event) {
        NotificationCenter.default.post(name: Notification.Name(e.rawValue), object: nil)
    }
}

struct ForgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CaptureIntent(), phrases: ["Capture in \(.applicationName)", "Add to \(.applicationName)"],
                    shortTitle: "Capture", systemImageName: "plus")
        AppShortcut(intent: OpenCaptureIntent(), phrases: ["Open \(.applicationName) capture"],
                    shortTitle: "Quick capture", systemImageName: "square.and.pencil")
        AppShortcut(intent: AskAssistantIntent(), phrases: ["Ask \(.applicationName)", "Tell \(.applicationName)"],
                    shortTitle: "Ask Forge", systemImageName: "sparkle")
    }
}
