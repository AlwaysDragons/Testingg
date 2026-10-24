import Foundation

enum APIError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey(let s): return "Add your \(s) API key in Settings."
        case .http(let code, let body):
            if code == 401 || code == 403 { return "API key rejected (\(code)). Check it in Settings." }
            if code == 429 { return "Rate limited — try again in a minute." }
            return "Request failed (\(code)): \(body.prefix(200))"
        case .badResponse: return "Unexpected response from server."
        }
    }
}

enum JSONCoding {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// Decoder for Hevy's snake_case JSON.
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoFrac.date(from: s) ?? iso.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized date \(s)")
        }
        return d
    }()

    /// Local cache coders (camelCase keys).
    static let cacheEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    static let cacheDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
