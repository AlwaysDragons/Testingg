import Foundation

/// Signed-in Supabase session (stored in the Keychain).
struct SupabaseSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String?
}

/// Minimal Supabase client: email-code auth + PostgREST. No SDK dependency.
/// Uses only the public anon key; Row Level Security protects every row.
actor SupabaseClient {
    let baseURL: URL
    let anonKey: String
    private(set) var session: SupabaseSession?
    private let onSessionChange: @Sendable (SupabaseSession?) -> Void

    init(baseURL: URL, anonKey: String, session: SupabaseSession?, onSessionChange: @escaping @Sendable (SupabaseSession?) -> Void) {
        self.baseURL = baseURL
        self.anonKey = anonKey
        self.session = session
        self.onSessionChange = onSessionChange
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: String; let email: String? }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: Auth

    /// Emails a 6-digit sign-in code.
    func sendCode(email: String) async throws {
        _ = try await send("POST", "auth/v1/otp", body: try JSONEncoder().encode(["email": JSONValue.string(email), "create_user": .bool(true)]), auth: false)
    }

    /// Exchanges the emailed code for a session.
    func verify(email: String, code: String) async throws {
        let body = try JSONEncoder().encode(["type": "email", "email": email, "token": code])
        let data = try await send("POST", "auth/v1/verify", body: body, auth: false)
        try setSession(from: data)
    }

    func signOut() async {
        if session != nil { _ = try? await send("POST", "auth/v1/logout", body: nil, auth: true) }
        updateSession(nil)
    }

    private func refreshIfNeeded() async throws {
        guard let s = session else { throw APIError.missingKey("Supabase sign-in") }
        guard s.expiresAt.timeIntervalSinceNow < 60 else { return }
        let body = try JSONEncoder().encode(["refresh_token": s.refreshToken])
        do {
            let data = try await send("POST", "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], body: body, auth: false)
            try setSession(from: data)
        } catch APIError.http(let code, let msg) where code == 400 || code == 401 {
            updateSession(nil)  // refresh token revoked/expired: sign in again
            throw APIError.http(code, msg)
        }
    }

    private func setSession(from data: Data) throws {
        let t = try Self.decoder.decode(TokenResponse.self, from: data)
        updateSession(SupabaseSession(accessToken: t.accessToken, refreshToken: t.refreshToken,
                                      expiresAt: Date().addingTimeInterval(t.expiresIn), userId: t.user.id, email: t.user.email))
    }

    private func updateSession(_ s: SupabaseSession?) {
        session = s
        onSessionChange(s)
    }

    // MARK: PostgREST

    /// Calls `/rest/v1/<table>`. Returns the raw response body.
    @discardableResult
    func rest(_ method: String, _ table: String, query: [URLQueryItem] = [], body: Data? = nil, prefer: String? = nil) async throws -> Data {
        try await refreshIfNeeded()
        return try await send(method, "rest/v1/\(table)", query: query, body: body, auth: true, prefer: prefer)
    }

    /// Calls the Edge Function `/functions/v1/<name>` as the signed-in user.
    func invoke(_ name: String, body: Data, timeout: TimeInterval = 90) async throws -> Data {
        try await refreshIfNeeded()
        return try await send("POST", "functions/v1/\(name)", body: body, auth: true, timeout: timeout)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try Self.decoder.decode(type, from: data)
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data?, auth: Bool, prefer: String? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(auth ? (session?.accessToken ?? anonKey) : anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
