import Foundation
import Observation

/// Coordinates Supabase sign-in and pushes every Integration into the cloud.
/// Configuration and session live in the Keychain (via the existing `Keychain` helper).
@Observable
@MainActor
final class CloudSync {
    enum AuthState: Equatable {
        case notConfigured
        case signedOut
        case codeSent(email: String)
        case signedIn(email: String)
    }

    struct ProviderStatus: Equatable {
        var state: String        // "Synced", "Syncing…", "Error"
        var detail: String
        var lastSynced: Date?
    }

    private(set) var auth: AuthState = .notConfigured
    private(set) var isSyncing = false
    private(set) var statuses: [String: ProviderStatus] = [:]
    var lastError: String?

    private(set) var projectURL: String
    private var client: SupabaseClient?
    private var rerunRequested = false

    private enum Key {
        static let url = "supabase_url"
        static let anon = "supabase_anon_key"
        static let session = "supabase_session"
    }

    init() {
        projectURL = Keychain.get(Key.url)
        rebuildClient(session: Self.loadSession())
    }

    /// The signed-in client, for the life dashboard's repository and realtime.
    var supabase: SupabaseClient? { isSignedIn ? client : nil }

    var isSignedIn: Bool { if case .signedIn = auth { return true } else { return false } }

    // MARK: Setup + auth

    /// Saves the project URL + anon (publishable) key. Refuses secret/service_role keys.
    func configure(url: String, anonKey: String) {
        guard !Self.isSecretKey(anonKey) else {
            lastError = "That is a secret (service_role) key. Use the anon / publishable key instead."
            return
        }
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), parsed.scheme == "https" else {
            lastError = "Project URL should look like https://abcd1234.supabase.co"
            return
        }
        lastError = nil
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Keychain.set(u, for: Key.url)
        Keychain.set(anonKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Key.anon)
        projectURL = u
        rebuildClient(session: nil)
    }

    func resetConfiguration() async {
        await client?.signOut()
        Keychain.set("", for: Key.url)
        Keychain.set("", for: Key.anon)
        projectURL = ""
        rebuildClient(session: nil)
    }

    func sendCode(email: String) async {
        guard let client else { return }
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            try await client.sendCode(email: e)
            auth = .codeSent(email: e)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func verify(code: String) async {
        guard let client, case .codeSent(let email) = auth else { return }
        do {
            try await client.verify(email: email, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            auth = .signedIn(email: email)
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func cancelCode() { auth = .signedOut }

    func signOut() async {
        await client?.signOut()
        auth = .signedOut
        statuses = [:]
    }

    // MARK: Sync

    /// Pushes each integration. If called while a sync is running, runs once more afterwards.
    func sync(_ integrations: [any Integration]) async {
        guard let client, isSignedIn else { return }
        guard !isSyncing else { rerunRequested = true; return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let repo = CloudRepository(client: client)
        for integration in integrations {
            let p = integration.provider
            statuses[p] = ProviderStatus(state: "Syncing…", detail: "", lastSynced: statuses[p]?.lastSynced)
            do {
                let state = try await repo.integrationState(p)
                let cursor = CloudRepository.parseDate(state?.config?.cursor)
                try await repo.setIntegration(p, status: "syncing", lastSyncedAt: nil, cursor: nil)
                let result = try await integration.sync(repo: repo, cursor: cursor)
                let now = Date()
                try await repo.setIntegration(p, status: "connected", lastSyncedAt: now, cursor: result.cursor)
                statuses[p] = ProviderStatus(state: "Synced", detail: result.summary, lastSynced: now)
            } catch {
                try? await repo.setIntegration(p, status: "error", lastSyncedAt: nil, cursor: nil)
                statuses[p] = ProviderStatus(state: "Error", detail: error.localizedDescription, lastSynced: statuses[p]?.lastSynced)
                lastError = "\(integration.displayName): \(error.localizedDescription)"
            }
        }
        if await client.session == nil { auth = .signedOut }  // refresh token expired mid-sync

        if rerunRequested {
            rerunRequested = false
            isSyncing = false
            await sync(integrations)
        }
    }

    /// True for keys that must never ship in an app: `sb_secret_…` or a JWT whose role is service_role.
    nonisolated static func isSecretKey(_ key: String) -> Bool {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.hasPrefix("sb_secret_") { return true }
        let parts = k.split(separator: ".")
        guard parts.count == 3 else { return false }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), let payload = String(data: data, encoding: .utf8) else { return false }
        return payload.contains("\"service_role\"")
    }

    // MARK: Private

    private func rebuildClient(session: SupabaseSession?) {
        let anon = Keychain.get(Key.anon)
        guard !projectURL.isEmpty, !anon.isEmpty, let url = URL(string: projectURL) else {
            client = nil
            auth = .notConfigured
            return
        }
        client = SupabaseClient(baseURL: url, anonKey: anon, session: session) { s in
            Task { @MainActor in CloudSync.saveSession(s) }
        }
        if let s = session { auth = .signedIn(email: s.email ?? "") } else { auth = .signedOut }
    }

    private static func loadSession() -> SupabaseSession? {
        let raw = Keychain.get(Key.session)
        guard !raw.isEmpty else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: Data(raw.utf8))
    }

    private static func saveSession(_ s: SupabaseSession?) {
        guard let s, let data = try? JSONEncoder().encode(s) else { Keychain.set("", for: Key.session); return }
        Keychain.set(String(decoding: data, as: UTF8.self), for: Key.session)
    }
}
