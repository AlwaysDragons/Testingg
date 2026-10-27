import Foundation
import Observation

/// "Skip or push today?" from the existing readiness score (HRV, resting HR, sleep, training load).
enum SkipOrPush {
    static func verdict(_ readiness: Int?) -> (label: String, status: Summaries.Status)? {
        guard let r = readiness else { return nil }
        switch r {
        case 70...: return ("Push today", .good)
        case 50..<70: return ("Train light today", .behind)
        default: return ("Rest or recover today", .overdue)
        }
    }
}

/// Notices new PRs from the existing Hevy analysis, once each.
enum PRWatcher {
    private static let key = "life.seenPRs"

    static func id(_ pr: PRRecord) -> String { "\(pr.title)|\(Int(pr.date.timeIntervalSince1970))" }

    /// PRs not seen before. The first run marks everything as seen (no backlog of celebrations).
    static func newPRs(_ prs: [PRRecord], seen: Set<String>?, now: Date = Date()) -> [PRRecord] {
        guard let seen else { return [] }
        return prs.filter { !seen.contains(id($0)) && now.timeIntervalSince($0.date) < 7 * 86_400 }
    }

    static func check(_ prs: [PRRecord]) -> [PRRecord] {
        let stored = UserDefaults.standard.stringArray(forKey: key).map(Set.init)
        let fresh = newPRs(prs, seen: stored)
        UserDefaults.standard.set(Array((stored ?? []).union(prs.map(id))), forKey: key)
        return fresh
    }
}

/// Daily nutrition targets live in the Nutrition area's config: {"targets": {"water_ml": 2500, "protein_g": 150, "calories": 2400},
/// "supplements": ["Creatine", "Vitamin D"]}.
enum Nutrition {
    struct Target: Equatable, Sendable, Identifiable {
        var id: String { metric }
        var metric: String
        var label: String
        var unit: String
        var goal: Double
        var today: Double
        var progress: Double { goal > 0 ? min(1, today / goal) : 0 }
    }

    static let defaults: [(String, String, String, Double)] = [
        ("water_ml", "Water", "ml", 2500), ("protein_g", "Protein", "g", 140), ("calories", "Calories", "kcal", 2400),
    ]

    static func targets(config: JSONValue, metrics: [Metric], now: Date = Date(), calendar: Calendar = .current) -> [Target] {
        defaults.map { metric, label, unit, fallback in
            let goal = config["targets"]?[metric]?.double ?? fallback
            let today = metrics.filter { $0.name == metric && calendar.isDate($0.recordedAt, inSameDayAs: now) }.map(\.value).reduce(0, +)
            return Target(metric: metric, label: label, unit: unit, goal: goal, today: today)
        }
    }

    static func supplements(config: JSONValue) -> [String] {
        config["supplements"]?.array.compactMap(\.string) ?? []
    }

    /// Supplements already logged today (logs with data.supplement).
    static func takenToday(_ logs: [LogEntry], now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        Set(logs.filter { calendar.isDate($0.loggedAt, inSameDayAs: now) }.compactMap { $0.data["supplement"]?.string })
    }
}

struct Measurement: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var type: String
    var value: Double
    var unit: String
    var recordedAt: Date
    var photoPath: String?
}

/// Body measurements + progress photos. Photos go to the private "photos" bucket (signed URLs only),
/// or stay on this device if you choose.
@Observable
@MainActor
final class MeasurementStore {
    private(set) var measurements: [Measurement] = []
    private var client: SupabaseClient?
    private var signed: [String: (URL, Date)] = [:]
    var photosOnDevice: Bool = UserDefaults.standard.bool(forKey: "measurements.photosOnDevice") {
        didSet { UserDefaults.standard.set(photosOnDevice, forKey: "measurements.photosOnDevice") }
    }
    private var localPhotos: [String: String] = UserDefaults.standard.dictionary(forKey: "measurements.localPhotos") as? [String: String] ?? [:]
    var lastError: String?

    func connect(_ client: SupabaseClient?) async {
        self.client = client
        await reload()
    }

    func reload() async {
        guard let client else { measurements = []; return }
        measurements = (try? await LifeRepository(client: client).get("body_measurements", ["select": "id,type,value,unit,recorded_at,photo_path", "order": "recorded_at.desc", "limit": "500"])) ?? []
    }

    var types: [String] { Array(Set(measurements.map(\.type))).sorted() }

    func add(type: String, value: Double, unit: String, photo: Data?) async {
        guard let client else { return }
        var path: String?
        var localName: String?
        if let photo {
            let name = UUID().uuidString.lowercased() + ".jpg"
            if photosOnDevice {
                if Self.saveLocal(photo, name: name) { localName = name }
            } else if let uid = await client.userId {
                path = "\(uid)/\(name)"
                do { try await client.upload(bucket: "photos", path: path!, data: photo, contentType: "image/jpeg") } catch { lastError = error.localizedDescription; path = nil }
            }
        }
        struct Recorded: Decodable { struct M: Decodable { var id: UUID }; var measurement: M }
        do {
            let r: Recorded = try await LifeRepository(client: client).rpc("ai_log_measurement", [
                "p_type": .string(type), "p_value": .number(value), "p_unit": .string(unit), "p_photo_path": .of(path),
            ])
            if let localName {
                localPhotos[r.measurement.id.uuidString] = localName
                UserDefaults.standard.set(localPhotos, forKey: "measurements.localPhotos")
            }
            lastError = nil
        } catch { lastError = error.localizedDescription }
        await reload()
    }

    func delete(_ m: Measurement) async {
        guard let client else { return }
        if let p = m.photoPath { try? await client.removeObject(bucket: "photos", path: p) }
        if let name = localPhotos.removeValue(forKey: m.id.uuidString) {
            try? FileManager.default.removeItem(at: Self.localURL(name))
            UserDefaults.standard.set(localPhotos, forKey: "measurements.localPhotos")
        }
        try? await LifeRepository(client: client).delete("body_measurements", id: m.id)
        await reload()
    }

    /// A URL to show the photo: a local file, or a fresh signed URL (cached for ~50 minutes).
    func photoURL(_ m: Measurement) async -> URL? {
        if let name = localPhotos[m.id.uuidString] { return Self.localURL(name) }
        guard let path = m.photoPath, let client else { return nil }
        if let (url, at) = signed[path], Date().timeIntervalSince(at) < 3000 { return url }
        guard let url = try? await client.signedURL(bucket: "photos", path: path) else { return nil }
        signed[path] = (url, Date())
        return url
    }

    private static func localURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("progress-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private static func saveLocal(_ data: Data, name: String) -> Bool {
        #if os(iOS)
        return (try? data.write(to: localURL(name), options: [.atomic, .completeFileProtection])) != nil
        #else
        return (try? data.write(to: localURL(name), options: [.atomic])) != nil
        #endif
    }
}
