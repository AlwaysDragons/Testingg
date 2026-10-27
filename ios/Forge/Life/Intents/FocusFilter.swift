import AppIntents
import Foundation

// Focus mode integration: in Settings → Focus → (Work / Gym / Personal) → Add Filter → Forge,
// pick which areas Home shows while that Focus is on.

/// An area, as App Intents sees it (from a catalog the app saves on every reload).
struct AreaEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Area"
    static let defaultQuery = AreaQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct AreaQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AreaEntity] {
        FocusAreas.catalog().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [AreaEntity] { FocusAreas.catalog() }
}

struct ForgeFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Choose areas"
    static let description = IntentDescription("Show only these areas on Forge's Home while this Focus is on.")

    @Parameter(title: "Areas")
    var areas: [AreaEntity]?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Forge areas", subtitle: "\(areas?.map(\.name).joined(separator: ", ") ?? "All areas")")
    }

    func perform() async throws -> some IntentResult {
        FocusAreas.setVisible(areas.map { Set($0.map(\.id)) })
        return .result()
    }
}

/// Which areas the current Focus allows (nil = all). Stored per device.
enum FocusAreas {
    private static let catalogKey = "focus.areaCatalog"
    private static let visibleKey = "focus.visibleAreaIds"
    static let changed = Notification.Name("forge.focusAreasChanged")

    static func saveCatalog(_ areas: [Area]) {
        let pairs = areas.filter { !$0.hidden }.map { [$0.id.uuidString, $0.name] }
        UserDefaults.standard.set(pairs, forKey: catalogKey)
    }

    static func catalog() -> [AreaEntity] {
        (UserDefaults.standard.array(forKey: catalogKey) as? [[String]] ?? []).compactMap { $0.count == 2 ? AreaEntity(id: $0[0], name: $0[1]) : nil }
    }

    static func visible() -> Set<String>? {
        (UserDefaults.standard.array(forKey: visibleKey) as? [String]).map(Set.init)
    }

    static func setVisible(_ ids: Set<String>?) {
        if let ids, !ids.isEmpty { UserDefaults.standard.set(Array(ids), forKey: visibleKey) } else { UserDefaults.standard.removeObject(forKey: visibleKey) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
