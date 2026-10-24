import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    // Data
    var workouts: [HevyWorkout] = []
    var templates: [String: HevyExerciseTemplate] = [:]
    var health = HealthData()
    private(set) var analysis = Analysis.empty
    private(set) var readiness: Readiness?
    private(set) var plan: [DayPlan] = []

    // Sync state
    var isSyncing = false
    var syncStatus = ""
    var lastHevySync: Date?
    var errorMessage: String?

    // Coach
    var chat: [ClaudeClient.Message] = []
    var isThinking = false
    var dailyBrief: String?
    var dailyBriefDate: Date?

    // Settings (UserDefaults-backed)
    var useLbs: Bool { didSet { defaults.set(useLbs, forKey: "useLbs"); recompute() } }
    var autoSchedule: Bool { didSet { defaults.set(autoSchedule, forKey: "autoSchedule"); recompute() } }
    var manualDays: Set<Int> { didSet { defaults.set(Array(manualDays), forKey: "manualDays"); recompute() } }
    var amenities: Set<Modality> { didSet { defaults.set(amenities.map(\.rawValue), forKey: "amenities"); recompute() } }
    var aiModel: String { didSet { defaults.set(aiModel, forKey: "aiModel") } }
    var goals: String { didSet { defaults.set(goals, forKey: "goals") } }
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }

    // Keys (Keychain-backed)
    var hevyKey: String { didSet { Keychain.set(hevyKey, for: "hevy") } }
    var claudeKey: String { didSet { Keychain.set(claudeKey, for: "claude") } }

    private let defaults = UserDefaults.standard
    private let healthKit = HealthKitManager()

    init() {
        let d = UserDefaults.standard
        useLbs = d.object(forKey: "useLbs") as? Bool ?? true
        autoSchedule = d.object(forKey: "autoSchedule") as? Bool ?? true
        manualDays = Set(d.array(forKey: "manualDays") as? [Int] ?? [2, 3, 5, 6])
        amenities = Set((d.array(forKey: "amenities") as? [String] ?? Modality.allCases.map(\.rawValue)).compactMap(Modality.init))
        aiModel = d.string(forKey: "aiModel") ?? ClaudeClient.models[0].id
        goals = d.string(forKey: "goals") ?? ""
        demoMode = d.object(forKey: "demoMode") as? Bool ?? false
        hevyKey = Keychain.get("hevy")
        claudeKey = Keychain.get("claude")
        loadCache()
        if workouts.isEmpty && health.isEmpty && hevyKey.isEmpty { loadDemo() }
        recompute()
    }

    var resolver: MuscleResolver { MuscleResolver(templates: templates) }
    var trainingDays: Set<Int> { autoSchedule ? Analyzer.inferredTrainingDays(workouts) : manualDays }
    var hasHevy: Bool { !hevyKey.isEmpty }
    var hasClaude: Bool { !claudeKey.isEmpty }

    func recompute() {
        analysis = Analyzer.analyze(workouts, resolver: resolver)
        readiness = Readiness.compute(health: health, analysis: analysis)
        plan = RecoveryPlanner.plan(trainingDays: trainingDays, workouts: workouts, resolver: resolver, amenities: amenities,
                                    readiness: readiness, lastSleepHours: health.sleepHours.latest?.value)
    }

    // MARK: - Sync

    func refreshAll(full: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false; syncStatus = "" }

        if hasHevy {
            if demoMode { workouts = []; templates = [:]; demoMode = false }
            await syncHevy(full: full)
        }
        await syncHealth()
        recompute()
        saveCache()
    }

    private func syncHevy(full: Bool) async {
        let client = HevyClient(apiKey: hevyKey)
        do {
            if templates.isEmpty || full {
                syncStatus = "Loading exercise library…"
                let t = try await client.allTemplates()
                templates = Dictionary(t.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            }
            syncStatus = "Syncing workouts…"
            workouts = try await client.syncWorkouts(existing: workouts, full: full) { page, total in
                Task { @MainActor in self.syncStatus = "Syncing workouts \(page)/\(total)…" }
            }
            lastHevySync = Date()
        } catch {
            errorMessage = "Hevy: " + error.localizedDescription
        }
    }

    private func syncHealth() async {
        guard healthKit.isAvailable else { return }
        do {
            syncStatus = "Reading Apple Health…"
            try await healthKit.requestAuthorization()
            let h = await healthKit.fetchAll()
            if !h.isEmpty || !demoMode { health = h }
        } catch {
            errorMessage = "Health: " + error.localizedDescription
        }
    }

    func loadDemo() {
        demoMode = true
        workouts = DemoData.workouts()
        health = DemoData.health()
        templates = [:]
        recompute()
    }

    func clearData() {
        workouts = []; templates = [:]; health = HealthData(); chat = []; dailyBrief = nil
        lastHevySync = nil; demoMode = false
        try? FileManager.default.removeItem(at: cacheURL)
        recompute()
    }

    // MARK: - AI

    private func systemPrompt() -> String {
        CoachContext.systemPrompt(workouts: workouts, health: health, analysis: analysis, readiness: readiness,
                                  plan: plan, resolver: resolver, lbs: useLbs, goals: goals)
    }

    func ask(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isThinking else { return }
        chat.append(.init(role: "user", content: q))
        isThinking = true
        defer { isThinking = false }
        do {
            var history = Array(chat.filter { !$0.content.hasPrefix("⚠️") }.suffix(20))
            while history.first?.role == "assistant" { history.removeFirst() }
            let reply = try await ClaudeClient(apiKey: claudeKey, model: aiModel)
                .send(system: systemPrompt(), messages: history)
            chat.append(.init(role: "assistant", content: reply))
        } catch {
            chat.append(.init(role: "assistant", content: "⚠️ " + error.localizedDescription))
        }
    }

    func generateDailyBrief() async {
        guard !isThinking else { return }
        isThinking = true
        defer { isThinking = false }
        do {
            dailyBrief = try await ClaudeClient(apiKey: claudeKey, model: aiModel).send(
                system: systemPrompt(),
                messages: [.init(role: "user", content: "Give me today's brief in under 120 words: readiness verdict, the exact workout focus or rest, one key lift target, and my OneLife recovery protocol for today.")],
                maxTokens: 600)
            dailyBriefDate = Date()
        } catch {
            dailyBrief = "⚠️ " + error.localizedDescription
        }
    }

    // MARK: - Cache

    private struct Cache: Codable {
        var workouts: [HevyWorkout]
        var templates: [HevyExerciseTemplate]
        var health: HealthData
        var lastHevySync: Date?
    }

    private var cacheURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("forge-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONCoding.cacheDecoder.decode(Cache.self, from: data) else { return }
        workouts = c.workouts
        templates = Dictionary(c.templates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        health = c.health
        lastHevySync = c.lastHevySync
    }

    func saveCache() {
        guard !demoMode else { return }
        let c = Cache(workouts: workouts, templates: Array(templates.values), health: health, lastHevySync: lastHevySync)
        if let data = try? JSONCoding.cacheEncoder.encode(c) {
            try? data.write(to: cacheURL, options: [.atomic, .completeFileProtection])
        }
    }
}
