import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hevyDraft = ""
    @State private var claudeDraft = ""
    @State private var confirmClear = false

    private let weekdays: [(Int, String)] = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    keyField("Hevy API key", text: $hevyDraft, saved: model.hevyKey) { key in
                        model.hevyKey = key
                        if !key.isEmpty { Task { await model.refreshAll(full: true) } }
                    }
                    Link("Get key: hevy.com → Settings → Developer (Pro)", destination: URL(string: "https://hevy.com/settings?developer")!)
                        .font(.footnote)
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        HStack {
                            Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if model.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(model.isSyncing)
                    Button("Full resync (all history)") { Task { await model.refreshAll(full: true) } }
                        .disabled(model.isSyncing || !model.hasHevy)
                    if !model.syncStatus.isEmpty { Text(model.syncStatus).font(.footnote).foregroundStyle(.secondary) }
                    if let d = model.lastHevySync {
                        LabeledContent("Last sync", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Workouts", value: "\(model.workouts.count)")
                } header: { Text("Hevy") }

                Section {
                    Button {
                        Task { await model.refreshAll() }
                    } label: { Label("Connect / refresh Apple Health", systemImage: "heart.fill") }
                    if let d = model.health.lastUpdated {
                        LabeledContent("Updated", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: { Text("Apple Health") } footer: {
                    Text("Reads sleep, HRV, resting HR, steps, energy, weight, body fat, VO₂ max, protein and calories. Nothing is written.")
                }

                Section {
                    keyField("Claude API key", text: $claudeDraft, saved: model.claudeKey) { model.claudeKey = $0 }
                    Link("Get key: console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.footnote)
                    Picker("Model", selection: $model.aiModel) {
                        ForEach(ClaudeClient.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    TextField("Goals & notes (e.g. 6'0\", lean bulk, bad left shoulder)", text: $model.goals, axis: .vertical)
                        .lineLimit(2...5)
                } header: { Text("AI Coach") } footer: {
                    Text("Keys are stored in the iOS Keychain on this device only. Your data is sent to Anthropic only when you ask the coach.")
                }

                Section {
                    Toggle("Auto-detect from history", isOn: $model.autoSchedule)
                    HStack(spacing: 6) {
                        ForEach(weekdays, id: \.0) { wd, label in
                            let on = model.trainingDays.contains(wd)
                            Button {
                                model.autoSchedule = false
                                if model.manualDays.contains(wd) { model.manualDays.remove(wd) } else { model.manualDays.insert(wd) }
                            } label: {
                                Text(label).font(.subheadline.weight(.bold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .background(Circle().fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card)))
                                    .foregroundStyle(on ? Color.white : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: { Text("Training days") }

                Section {
                    ForEach(Modality.allCases) { m in
                        Toggle(isOn: Binding(
                            get: { model.amenities.contains(m) },
                            set: { if $0 { model.amenities.insert(m) } else { model.amenities.remove(m) } }
                        )) {
                            Label { Text(m.name) } icon: { Image(systemName: m.icon).foregroundStyle(Theme.color(m)) }
                        }
                    }
                } header: { Text("OneLife amenities at my club") }

                Section {
                    Toggle("Use pounds (lb)", isOn: $model.useLbs)
                    Button("Load sample data") { model.loadDemo() }
                    Button("Clear all data", role: .destructive) { confirmClear = true }
                } header: { Text("App") }
            }
            .screen()
            .navigationTitle("Settings")
            .confirmationDialog("Delete cached workouts, health data and chat?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { model.clearData() }
            }
            .onAppear {
                hevyDraft = model.hevyKey
                claudeDraft = model.claudeKey
            }
        }
    }

    private func keyField(_ title: String, text: Binding<String>, saved: String, onSave: @escaping (String) -> Void) -> some View {
        HStack {
            SecureField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { onSave(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if text.wrappedValue != saved {
                Button("Save") { onSave(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            } else if !saved.isEmpty {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.mint)
            }
        }
    }
}
