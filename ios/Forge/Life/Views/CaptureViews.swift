import AVFoundation
import Speech
import SwiftUI

/// One-tap capture: type or dictate, save, and see where it landed (with undo). Under 10 seconds.
struct CaptureSheet: View {
    @Environment(CaptureStore.self) private var captures
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dictation = Dictation()
    @State private var state: Phase = .editing
    @FocusState private var focused: Bool

    enum Phase: Equatable { case editing, saving, done(id: UUID, summary: String, sorted: Bool), failed }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                switch state {
                case .editing, .saving:
                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .font(DS.Typo.body)
                        .lineLimit(3...8)
                        .focused($focused)
                        .padding(DS.Space.m)
                        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    if let e = dictation.error { Text(e).font(DS.Typo.caption).foregroundStyle(DS.Palette.critical) }
                    Spacer()
                    Button { save() } label: {
                        if state == .saving { ProgressView().tint(.white) } else { Text("Save") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state == .saving)
                case .done(let id, let summary, let sorted):
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(sorted ? "Sorted" : "Saved to inbox").font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                        Text(summary).font(DS.Typo.title)
                    }
                    Spacer()
                    if sorted {
                        Button("Undo") {
                            Task {
                                await captures.undo(id)
                                await store.reloadAll()
                                dismiss()
                            }
                        }
                        .font(DS.Typo.body)
                        .frame(maxWidth: .infinity)
                    }
                case .failed:
                    Text("Couldn't save. Check your connection and try again.").font(DS.Typo.body).foregroundStyle(DS.Palette.critical)
                    Spacer()
                }
            }
            .padding(DS.Space.m)
            .dsScreen()
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if state == .editing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await dictation.toggle { text = $0 } }
                        } label: {
                            Image(systemName: dictation.isRecording ? "stop.circle" : "mic")
                        }
                        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                    }
                }
            }
            .onAppear {
                text = captures.prefill
                focused = true
            }
            .onDisappear { dictation.stop() }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        dictation.stop()
        state = .saving
        let source = dictation.used ? "voice" : "text"
        Task {
            guard let saved = await captures.capture(text, source: source) else { state = .failed; return }
            let (id, outcome) = saved
            DS.Haptics.success()
            state = .done(id: id, summary: outcome?.summary ?? "Saved. It will be sorted later.", sorted: outcome?.sorted ?? false)
            await store.reloadAll()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .done = state { dismiss() }
        }
    }
}

/// On-device dictation with the Speech framework. Permission is asked on first use.
@Observable
@MainActor
final class Dictation {
    private(set) var isRecording = false
    private(set) var used = false
    private(set) var error: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()

    func toggle(onText: @escaping @MainActor (String) -> Void) async {
        if isRecording { stop(); return }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic, let recognizer, recognizer.isAvailable else {
            error = "Allow speech recognition and the microphone in Settings to dictate."
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in req.append(buffer) }
            engine.prepare()
            try engine.start()
            isRecording = true
            used = true
            error = nil
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    if let text { onText(text) }
                    if err != nil || final { self?.stop() }
                }
            }
        } catch {
            self.error = "Dictation isn't available right now."
            stop()
        }
    }

    func stop() {
        guard isRecording || task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Captures waiting to be sorted, and recently sorted ones (with undo).
struct InboxView: View {
    @Environment(CaptureStore.self) private var captures
    @Environment(LifeStore.self) private var store
    @State private var sorting: UUID?

    var body: some View {
        List {
            if captures.inbox.isEmpty && captures.recent.isEmpty {
                Section { EmptyState(symbol: "tray", title: "Inbox is empty", message: "Captures that couldn't be sorted wait here.") }
                    .listRowBackground(DS.Palette.surface)
            }
            if !captures.inbox.isEmpty {
                Section {
                    ForEach(captures.inbox) { c in
                        ListRow(title: c.rawText, subtitle: c.createdAt.formatted(.relative(presentation: .named)), symbol: c.source == "voice" ? "mic" : "text.alignleft") {
                            if sorting == c.id { ProgressView().controlSize(.small) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Sort", systemImage: "sparkle") {
                                sorting = c.id
                                Task { _ = await captures.sort(c); await store.reloadAll(); sorting = nil }
                            }
                            .tint(DS.Palette.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { Task { await captures.delete(c) } }
                        }
                    }
                } header: { SectionHeader(title: "To sort") }
                .listRowBackground(DS.Palette.surface)
            }
            if !captures.recent.isEmpty {
                Section {
                    ForEach(captures.recent.prefix(20)) { c in
                        ListRow(title: c.summary ?? c.rawText, subtitle: c.rawText, symbol: "checkmark")
                            .swipeActions(edge: .trailing) {
                                Button("Undo", systemImage: "arrow.uturn.backward") {
                                    Task { await captures.undo(c.id); await store.reloadAll() }
                                }
                            }
                    }
                } header: { SectionHeader(title: "Sorted") }
                .listRowBackground(DS.Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Inbox")
        .refreshable { await captures.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { captures.open() } label: { Image(systemName: "plus") }.accessibilityLabel("Capture")
            }
        }
    }
}
