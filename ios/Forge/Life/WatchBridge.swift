import Foundation
import WatchConnectivity

/// Phone side of the Apple Watch companion. Sends the widget snapshot to the watch and runs the watch's
/// actions (habit tap, quick capture, check-in) here, with the phone's Supabase session.
@MainActor
final class WatchBridge: NSObject {
    static let shared = WatchBridge()
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    /// Latest snapshot as application context (the watch always gets the newest one).
    func send(_ snapshot: WidgetSnapshot?) {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let snapshot, let data = try? JSONEncoder.watch.encode(snapshot) else { return }
        try? session.updateApplicationContext(["snapshot": data])
    }

    /// Handles {"action": "logHabit", "id"} / {"action": "capture", "text"} / {"action": "checkin", "type", "mood", "energy"}.
    static func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let client = CloudSync().supabase else { return ["ok": false, "error": "Sign in on your iPhone first."] }
        switch message["action"] as? String {
        case "logHabit":
            guard let id = message["id"] as? String else { return ["ok": false] }
            await HabitActions.log(itemId: id)
            return ["ok": true]
        case "capture":
            guard let text = message["text"] as? String,
                  let saved = await CaptureStore.capture(text, source: "widget", client: client) else { return ["ok": false] }
            IntentEvents.post(.dashboardChanged)
            return ["ok": true, "summary": saved.1?.summary ?? "Saved to your inbox."]
        case "checkin":
            var p: [String: JSONValue] = ["type": .string(message["type"] as? String ?? EverydayStore.currentType())]
            if let m = message["mood"] as? Int { p["mood"] = .int(m) }
            if let e = message["energy"] as? Int { p["energy"] = .int(e) }
            let r: JSONValue? = try? await LifeRepository(client: client).rpc("ai_submit_checkin", ["p": .object(p)])
            return ["ok": r != nil]
        default:
            return ["ok": false]
        }
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchBridge.shared.send(WidgetSnapshot.load()) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let box = MessageBox(message)
        Task { @MainActor in
            let reply = await WatchBridge.handle(box.value)
            replyHandler(reply)
            WatchBridge.shared.send(WidgetSnapshot.load())
        }
    }
}

/// Lets a [String: Any] cross into a Task (property-list values only).
private struct MessageBox: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }

extension JSONEncoder {
    static let watch: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
}
