import Foundation

/// Parses "#5B8CFF" / "5B8CFF" / "#5B8" into 0...1 RGB components. Pure, so it is unit-testable.
/// Used for `areas.color`, the one accent each area gets.
struct RGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        red = Double((v >> 16) & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double(v & 0xFF) / 255
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

/// The accent choices offered when creating or editing an area. Muted so they work in light and dark mode.
enum AreaPalette {
    static let accents: [String] = ["#5B8CFF", "#34C3A0", "#F2A93B", "#E86A5C", "#A47CF3", "#4FB3D9", "#8E8E93"]
    static let fallback = "#5B8CFF"

    /// The accent for an area kind when the area has no color set.
    static func defaultHex(forKind kind: String) -> String {
        switch kind {
        case "gym": return "#E86A5C"
        case "tasks": return "#5B8CFF"
        case "goals": return "#A47CF3"
        case "habits": return "#34C3A0"
        case "finance": return "#F2A93B"
        case "dev": return "#4FB3D9"
        default: return "#8E8E93"
        }
    }

    /// SF Symbol for an area kind when the area has no icon set.
    static func defaultSymbol(forKind kind: String) -> String {
        switch kind {
        case "gym": return "dumbbell"
        case "tasks": return "checklist"
        case "goals": return "flag"
        case "habits": return "repeat"
        case "finance": return "creditcard"
        case "dev": return "chevron.left.forwardslash.chevron.right"
        default: return "square.grid.2x2"
        }
    }
}
