import Foundation

enum Fmt {
    static let kgToLb = 2.20462

    static func weight(_ kg: Double, lbs: Bool, decimals: Int = 0) -> String {
        let v = lbs ? kg * kgToLb : kg
        return String(format: "%.\(decimals)f", v) + (lbs ? " lb" : " kg")
    }

    static func weightValue(_ kg: Double, lbs: Bool) -> Double { lbs ? kg * kgToLb : kg }

    static func set(_ s: HevySet, lbs: Bool) -> String {
        if let w = s.weightKg, w > 0, let r = s.reps {
            let v = lbs ? w * kgToLb : w
            return "\(Int(v.rounded()))×\(r)"
        }
        if let r = s.reps { return "BW×\(r)" }
        if let d = s.durationSeconds { return "\(Int(d))s" }
        if let m = s.distanceMeters { return "\(Int(m))m" }
        return "—"
    }

    static func compact(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.0fk", v / 1_000) }
        if v >= 1_000 { return String(format: "%.1fk", v / 1_000) }
        return String(format: "%.0f", v)
    }

    static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    static let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    static let iso: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
}
