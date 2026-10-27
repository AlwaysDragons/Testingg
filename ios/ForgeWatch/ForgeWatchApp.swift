import SwiftUI
import WatchConnectivity

// Apple Watch companion: today at a glance, habit taps, quick capture (dictation) and check-in.
// Everything goes through the iPhone app (WatchConnectivity), which holds the Supabase session.

@main
struct ForgeWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.snapshot?.line ?? "Open Forge on your iPhone to sync.").font(.footnote)
                            if let s = model.snapshot {
                                Text("\(s.dueToday) due · \(s.overdue) overdue · \(s.habitsLeft) habits left")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let habits = model.snapshot?.habits, !habits.isEmpty {
                        Section("Habits") {
                            ForEach(habits) { h in
                                Button { model.logHabit(h.id) } label: {
                                    Label(h.title, systemImage: h.doneToday || model.done.contains(h.id) ? "checkmark.circle.fill" : "circle")
                                }
                                .disabled(h.doneToday || model.done.contains(h.id))
                            }
                        }
                    }
                    Section {
                        NavigationLink { CaptureView(model: model) } label: { Label("Capture", systemImage: "plus") }
                        NavigationLink { CheckinView(model: model) } label: { Label("Check in", systemImage: "sun.horizon") }
                    }
                    if let status = model.status { Text(status).font(.caption2).foregroundStyle(.secondary) }
                }
                .navigationTitle("Forge")
            }
            .onAppear { model.activate() }
        }
    }
}

@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    var snapshot: WidgetSnapshot?
    var done: Set<String> = []
    var status: String?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        apply(WCSession.default.receivedApplicationContext)
    }

    func logHabit(_ id: String) {
        done.insert(id)
        send(["action": "logHabit", "id": id])
    }

    func capture(_ text: String) { send(["action": "capture", "text": text]) }

    func checkin(mood: Int, energy: Int) { send(["action": "checkin", "mood": mood, "energy": energy]) }

    private func send(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            status = "Open Forge on your iPhone and try again."
            return
        }
        WCSession.default.sendMessage(message, replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? false
            let summary = reply["summary"] as? String
            DispatchQueue.main.async { self.status = ok ? (summary ?? "Done") : (reply["error"] as? String ?? "Couldn't do that.") }
        }, errorHandler: { _ in
            DispatchQueue.main.async { self.status = "Couldn't reach your iPhone." }
        })
    }

    private func apply(_ context: [String: Any]) {
        guard let data = context["snapshot"] as? Data else { return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        if let s = try? d.decode(WidgetSnapshot.self, from: data) {
            snapshot = s
            done = []
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        DispatchQueue.main.async { self.apply(context) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.apply(applicationContext) }
    }
}

struct CaptureView: View {
    let model: WatchModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            TextField("Say or type it", text: $text)
            Button("Save") {
                model.capture(text)
                dismiss()
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("Capture")
    }
}

struct CheckinView: View {
    let model: WatchModel
    @State private var mood = 3
    @State private var energy = 3
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Stepper("Mood \(mood)", value: $mood, in: 1...5)
                Stepper("Energy \(energy)", value: $energy, in: 1...5)
                Button("Save") {
                    model.checkin(mood: mood, energy: energy)
                    dismiss()
                }
            }
        }
        .navigationTitle("Check in")
    }
}
