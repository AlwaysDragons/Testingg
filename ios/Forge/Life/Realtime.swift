import Foundation

/// Minimal Supabase Realtime client (Phoenix protocol over a WebSocket, no SDK).
/// Subscribes to Postgres changes in the `public` schema; RLS limits events to the user's own rows.
/// Calls `onChange(table)` for every change so the store can reload that table.
actor RealtimeClient {
    private let client: SupabaseClient
    private let onChange: @Sendable (String) -> Void
    private var socket: URLSessionWebSocketTask?
    private var ref = 0
    private var loops: [Task<Void, Never>] = []
    private var running = false
    private var attempt = 0
    static let topic = "realtime:forge-life"

    init(client: SupabaseClient, onChange: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.onChange = onChange
    }

    func start() {
        guard !running else { return }
        running = true
        Task { await connect() }
    }

    func stop() {
        running = false
        loops.forEach { $0.cancel() }
        loops = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func nextRef() -> String {
        ref += 1
        return String(ref)
    }

    private func connect() async {
        guard running else { return }
        do {
            let token = try await client.accessToken()
            let base = client.baseURL.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
            guard let url = URL(string: "\(base)/realtime/v1/websocket?apikey=\(client.anonKey)&vsn=1.0.0") else { return }
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            try await send(Self.joinMessage(token: token, ref: nextRef()))
            attempt = 0
            loops = [
                Task { [weak self] in await self?.receiveLoop() },
                Task { [weak self] in await self?.heartbeatLoop() },
            ]
        } catch {
            await reconnectLater()
        }
    }

    private func reconnectLater() async {
        loops.forEach { $0.cancel() }
        loops = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard running else { return }
        attempt += 1
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))  // 2s ... 30s
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await connect()
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, let table = Self.changedTable(in: text) { onChange(table) }
            } catch {
                if !Task.isCancelled { Task { await self.reconnectLater() } }
                return
            }
        }
    }

    /// Heartbeat every 25 s; refreshes the channel's access token about every 10 minutes.
    private func heartbeatLoop() async {
        var beats = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard !Task.isCancelled else { return }
            beats += 1
            do {
                try await send(#"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"\#(nextRef())"}"#)
                if beats % 24 == 0, let token = try? await client.accessToken() {
                    try await send(Self.tokenMessage(token: token, ref: nextRef()))
                }
            } catch {
                return  // the receive loop notices the broken socket and reconnects
            }
        }
    }

    private func send(_ text: String) async throws {
        guard let socket else { throw APIError.badResponse }
        try await socket.send(.string(text))
    }

    // MARK: Protocol messages (pure, unit-tested)

    static func joinMessage(token: String, ref: String) -> String {
        let payload: [String: Any] = [
            "config": [
                "broadcast": ["self": false],
                "presence": ["key": ""],
                "postgres_changes": [["event": "*", "schema": "public"]],
            ],
            "access_token": token,
        ]
        return encode(["topic": topic, "event": "phx_join", "payload": payload, "ref": ref, "join_ref": ref])
    }

    static func tokenMessage(token: String, ref: String) -> String {
        encode(["topic": topic, "event": "access_token", "payload": ["access_token": token], "ref": ref])
    }

    /// The table named by a `postgres_changes` event, or nil for any other message.
    static func changedTable(in text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["event"] as? String == "postgres_changes",
              let payload = obj["payload"] as? [String: Any],
              let change = payload["data"] as? [String: Any],
              let table = change["table"] as? String else { return nil }
        return table
    }

    private static func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
