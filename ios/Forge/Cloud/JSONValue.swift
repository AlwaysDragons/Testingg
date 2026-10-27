import Foundation

/// A JSON value that always encodes nil as `null`.
/// PostgREST bulk upserts require every row to have the same keys, and Codable would drop nil fields.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    // MARK: Reading jsonb (areas.config, items.data, ...)

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
    var string: String? { if case .string(let v) = self { return v } else { return nil } }
    var double: Double? {
        switch self {
        case .number(let v): return v
        case .int(let v): return Double(v)
        case .string(let v): return Double(v)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var object: [String: JSONValue] { if case .object(let o) = self { return o } else { return [:] } }
    var array: [JSONValue] { if case .array(let a) = self { return a } else { return [] } }

    /// Returns a copy of this object with `key` set (non-objects become objects).
    func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        var o = object
        o[key] = value
        return .object(o)
    }

    static let emptyObject = JSONValue.object([:])

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func of(_ v: String?) -> JSONValue { v.map { .string($0) } ?? .null }
    static func of(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }
    static func of(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }
    static func of(_ v: Date?) -> JSONValue { v.map { .string(iso.string(from: $0)) } ?? .null }
    static func of(_ v: UUID?) -> JSONValue { v.map { .string($0.uuidString.lowercased()) } ?? .null }
    static func of(_ v: Bool?) -> JSONValue { v.map { .bool($0) } ?? .null }
    static func of(_ v: [String]) -> JSONValue { .array(v.map { .string($0) }) }
}

/// One table row for an insert/upsert.
typealias Row = [String: JSONValue]
