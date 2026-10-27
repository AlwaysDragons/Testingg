import Foundation
import LocalAuthentication
import Observation

/// Face ID lock per area (`areas.config.locked`). Unlocked areas stay open until the app goes to the background.
@Observable
@MainActor
final class AreaLock {
    private(set) var unlocked: Set<UUID> = []

    static func isLocked(_ area: Area) -> Bool { area.config["locked"]?.bool ?? false }

    func isOpen(_ area: Area) -> Bool { !Self.isLocked(area) || unlocked.contains(area.id) }

    func unlock(_ area: Area) async -> Bool {
        guard Self.isLocked(area) else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        let ok = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock \(area.name)")) ?? false
        if ok { unlocked.insert(area.id) }
        return ok
    }

    func lockAll() { unlocked = [] }
}
