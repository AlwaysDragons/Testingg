import Foundation

/// A JSON value that always encodes nil as `null`.
/// PostgREST bulk upserts require every row to have the same keys, and Codable would drop nil fields.
enum JSONValue: Encodable, Equatable {
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
}

/// One table row for an insert/upsert.
typealias Row = [String: JSONValue]
