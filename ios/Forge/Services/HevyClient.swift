import Foundation

/// Minimal client for the Hevy public API. Requires Hevy Pro — get a key at hevy.com → Settings → Developer.
struct HevyClient {
    let apiKey: String
    private let base = URL(string: "https://api.hevyapp.com/v1/")!

    struct WorkoutPage: Decodable { let page: Int; let pageCount: Int; let workouts: [HevyWorkout] }
    struct TemplatePage: Decodable { let page: Int; let pageCount: Int; let exerciseTemplates: [HevyExerciseTemplate] }
    struct Count: Decodable { let workoutCount: Int }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard !apiKey.isEmpty else { throw APIError.missingKey("Hevy") }
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "api-key")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONCoding.api.decode(T.self, from: data)
    }

    func workoutCount() async throws -> Int {
        let c: Count = try await get("workouts/count")
        return c.workoutCount
    }

    func workouts(page: Int) async throws -> WorkoutPage {
        try await get("workouts", ["page": "\(page)", "pageSize": "10"])
    }

    func templates(page: Int) async throws -> TemplatePage {
        try await get("exercise_templates", ["page": "\(page)", "pageSize": "100"])
    }

    /// Fetches workouts newest-first. Stops early once a page is entirely unchanged vs. the cache (incremental sync).
    func syncWorkouts(existing: [HevyWorkout], full: Bool, progress: (Int, Int) -> Void) async throws -> [HevyWorkout] {
        var merged = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var page = 1
        while true {
            let p = try await workouts(page: page)
            progress(page, p.pageCount)
            var unchanged = true
            for w in p.workouts {
                if merged[w.id]?.updatedAt != w.updatedAt || merged[w.id] == nil { unchanged = false }
                merged[w.id] = w
            }
            if page >= p.pageCount || p.workouts.isEmpty { break }
            if !full && unchanged && !existing.isEmpty { break }
            page += 1
        }
        return merged.values.sorted { $0.startTime > $1.startTime }
    }

    func allTemplates() async throws -> [HevyExerciseTemplate] {
        var out: [HevyExerciseTemplate] = []
        var page = 1
        while true {
            let p = try await templates(page: page)
            out += p.exerciseTemplates
            if page >= p.pageCount || p.exerciseTemplates.isEmpty { break }
            page += 1
        }
        return out
    }
}
