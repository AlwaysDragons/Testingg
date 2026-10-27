import PhotosUI
import UIKit
import SwiftUI

/// A subtle PR card: shown once per new PR, with a haptic. Dismiss by tapping.
@Observable
@MainActor
final class Celebrations {
    var pr: PRRecord?

    /// Call after each Hevy refresh.
    func check(_ model: AppModel) {
        let fresh = PRWatcher.check(model.analysis.recentPRs)
        if let p = fresh.max(by: { $0.date < $1.date }) {
            pr = p
            DS.Haptics.success()
        }
    }
}

struct PRBanner: View {
    @Environment(AppModel.self) private var model
    let pr: PRRecord
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "trophy").font(.title3.weight(DS.symbolWeight)).foregroundStyle(DS.Palette.area(hex: nil, kind: "gym"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New PR: \(pr.title)").font(DS.Typo.bodyEmphasis)
                    Text("\(Fmt.weight(pr.e1rm, lbs: model.useLbs)) estimated 1RM, up from \(Fmt.weight(pr.previousBest, lbs: model.useLbs))")
                        .font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                }
                Spacer(minLength: 0)
            }
            .dsCard()
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityHint("Dismiss")
    }
}

/// Recovery ring (0-100) from the existing readiness score, with its factors and today's verdict.
struct RecoverySection: View {
    @Environment(AppModel.self) private var model
    let accent: Color

    var body: some View {
        if let r = model.readiness {
            Section {
                HStack(spacing: DS.Space.l) {
                    ZStack {
                        ProgressRing(progress: Double(r.score) / 100, accent: accent, lineWidth: 8, size: 72)
                        Text("\(r.score)").font(DS.Typo.bodyEmphasis).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(SkipOrPush.verdict(r.score)?.label ?? r.label).font(DS.Typo.bodyEmphasis)
                        Text(r.advice).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary).lineLimit(3)
                    }
                }
                .padding(.vertical, DS.Space.s)
                ForEach(r.factors) { f in
                    ListRow(title: f.name, subtitle: f.detail) { RowValue(text: f.value) }
                }
            } header: { SectionHeader(title: "Recovery") }
            .listRowBackground(DS.Palette.surface)
        }
    }
}

// MARK: - Nutrition

/// Water, protein, calories against targets, plus supplements. Quick-log in a couple of taps.
struct NutritionSection: View {
    @Environment(LifeStore.self) private var store
    let area: Area
    @State private var showLog = false

    var body: some View {
        let accent = DS.Palette.area(hex: area.color, kind: area.kind)
        let targets = Nutrition.targets(config: area.config, metrics: store.metrics(in: area))
        Section {
            HStack {
                ForEach(targets) { t in
                    VStack(spacing: DS.Space.xs) {
                        ProgressRing(progress: t.progress, accent: accent, lineWidth: 5, size: 44)
                        Text(Summaries.number(t.today)).font(DS.Typo.bodyEmphasis).monospacedDigit()
                        Text(t.label).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(t.label) \(Summaries.number(t.today)) of \(Summaries.number(t.goal)) \(t.unit)")
                }
            }
            .padding(.vertical, DS.Space.s)
            Button("Quick log") { showLog = true }
        } header: { SectionHeader(title: "Today") }
        .listRowBackground(DS.Palette.surface)
        .sheet(isPresented: $showLog) { NutritionLogSheet(area: area) }
    }
}

struct NutritionLogSheet: View {
    @Environment(LifeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let area: Area
    @State private var protein = ""
    @State private var calories = ""
    @State private var meal = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Water") {
                    HStack {
                        ForEach([250, 500, 750], id: \.self) { ml in
                            Button("+\(ml) ml") { log("water_ml", Double(ml), "ml") }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .listRowBackground(DS.Palette.surface)
                Section("Meal") {
                    TextField("What did you eat?", text: $meal)
                    TextField("Protein (g)", text: $protein).keyboardType(.decimalPad)
                    TextField("Calories", text: $calories).keyboardType(.numberPad)
                    Button("Log meal") {
                        if let p = Double(protein.replacingOccurrences(of: ",", with: ".")) { log("protein_g", p, "g") }
                        if let c = Double(calories) { log("calories", c, "kcal") }
                        if !meal.trimmingCharacters(in: .whitespaces).isEmpty {
                            Task { await store.addLog(to: area, note: meal, data: .object(["meal": .bool(true)])) }
                        }
                        dismiss()
                    }
                    .disabled(meal.isEmpty && protein.isEmpty && calories.isEmpty)
                }
                .listRowBackground(DS.Palette.surface)
                let supplements = Nutrition.supplements(config: area.config)
                if !supplements.isEmpty {
                    let taken = Nutrition.takenToday(store.logs(in: area))
                    Section("Supplements") {
                        ForEach(supplements, id: \.self) { s in
                            Button {
                                guard !taken.contains(s) else { return }
                                DS.Haptics.success()
                                Task { await store.addLog(to: area, note: s, data: .object(["supplement": .string(s)])) }
                            } label: {
                                ListRow(title: s, symbol: taken.contains(s) ? "checkmark.circle.fill" : "circle",
                                        accent: taken.contains(s) ? DS.Palette.positive : DS.Palette.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(DS.Palette.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("Log nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func log(_ name: String, _ value: Double, _ unit: String) {
        DS.Haptics.tap()
        Task { await store.addMetric(to: area, name: name, value: value, unit: unit) }
    }
}

extension LifeStore {
    /// The Nutrition area, created with default targets the first time it's needed.
    func nutritionArea() async -> Area? {
        if let a = areas.first(where: { $0.config["targets"] != nil }) ?? area(named: "Nutrition") { return a }
        guard let a = await createArea(name: "Nutrition", kind: "custom", icon: "drop", color: "#4FB3D9") else { return nil }
        let targets = JSONValue.object(Dictionary(uniqueKeysWithValues: Nutrition.defaults.map { ($0.0, JSONValue.number($0.3)) }))
        await updateArea(a, ["config": a.config.setting("targets", targets).setting("supplements", .array([]))])
        return area(a.id)
    }
}

// MARK: - Measurements + progress photos

struct MeasurementsView: View {
    @Environment(MeasurementStore.self) private var measurements
    @State private var showAdd = false

    var body: some View {
        @Bindable var measurements = measurements
        List {
            if measurements.measurements.isEmpty {
                Section { EmptyState(symbol: "ruler", title: "No measurements yet", message: "Track waist, arms, body fat and progress photos.", actionTitle: "Add") { showAdd = true } }
                    .listRowBackground(DS.Palette.surface)
            }
            ForEach(measurements.types, id: \.self) { type in
                let series = measurements.measurements.filter { $0.type == type }
                Section {
                    if let last = series.first {
                        StatView(value: Summaries.number(last.value) + " " + last.unit, label: type.capitalizedFirst,
                                 secondary: series.count > 1 ? change(series) : last.recordedAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if series.count > 1 { TrendLine(values: series.reversed().map(\.value)) }
                } header: { SectionHeader(title: type.capitalizedFirst) }
                .listRowBackground(DS.Palette.surface)
            }
            let withPhotos = measurements.measurements.filter { $0.photoPath != nil || hasLocal($0) }
            if !withPhotos.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DS.Space.s) { ForEach(withPhotos) { PhotoThumb(measurement: $0) } }
                    }
                } header: { SectionHeader(title: "Progress photos") }
                .listRowBackground(DS.Palette.surface)
            }
            Section {
                Toggle("Keep photos on this device only", isOn: $measurements.photosOnDevice)
            } footer: {
                Text("Otherwise photos go to your private Supabase bucket and are only shown through short-lived signed links.")
            }
            .listRowBackground(DS.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .dsScreen()
        .navigationTitle("Measurements")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add measurement") } }
        .sheet(isPresented: $showAdd) { AddMeasurementSheet() }
        .refreshable { await measurements.reload() }
    }

    private func change(_ series: [Measurement]) -> String {
        guard let last = series.first, let first = series.last else { return "" }
        let d = last.value - first.value
        return (d >= 0 ? "+" : "") + Summaries.number(d) + " " + last.unit + " since " + first.recordedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func hasLocal(_ m: Measurement) -> Bool {
        (UserDefaults.standard.dictionary(forKey: "measurements.localPhotos") as? [String: String])?[m.id.uuidString] != nil
    }
}

private struct PhotoThumb: View {
    @Environment(MeasurementStore.self) private var measurements
    let measurement: Measurement
    @State private var url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                DS.Palette.raised
            }
            .frame(width: 96, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            Text(measurement.recordedAt.formatted(date: .abbreviated, time: .omitted)).font(DS.Typo.caption).foregroundStyle(DS.Palette.secondary)
        }
        .task { url = await measurements.photoURL(measurement) }
        .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { Task { await measurements.delete(measurement) } } }
    }
}

private struct AddMeasurementSheet: View {
    @Environment(MeasurementStore.self) private var measurements
    @Environment(\.dismiss) private var dismiss
    @State private var type = "waist"
    @State private var value = ""
    @State private var unit = "cm"
    @State private var item: PhotosPickerItem?
    @State private var photo: Data?
    private let types = ["waist", "chest", "arm", "thigh", "hips", "neck", "body_fat", "weight"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) { ForEach(types, id: \.self) { Text(Summaries.label(forMetric: $0).capitalizedFirst).tag($0) } }
                    HStack {
                        TextField("Value", text: $value).keyboardType(.decimalPad)
                        Picker("Unit", selection: $unit) { ForEach(["cm", "in", "%", "kg", "lb"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                    PhotosPicker(selection: $item, matching: .images) {
                        Label(photo == nil ? "Add progress photo" : "Photo added", systemImage: photo == nil ? "camera" : "checkmark")
                    }
                }
                .listRowBackground(DS.Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .dsScreen()
            .navigationTitle("New measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = Double(value.replacingOccurrences(of: ",", with: ".")) else { return }
                        Task { await measurements.add(type: type, value: v, unit: unit, photo: photo); dismiss() }
                    }
                    .disabled(Double(value.replacingOccurrences(of: ",", with: ".")) == nil)
                }
            }
            .onChange(of: type) { _, t in unit = t == "body_fat" ? "%" : t == "weight" ? "kg" : "cm" }
            .onChange(of: item) { _, new in
                Task {
                    guard let data = try? await new?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                    photo = img.jpegData(compressionQuality: 0.7)
                }
            }
        }
    }
}
