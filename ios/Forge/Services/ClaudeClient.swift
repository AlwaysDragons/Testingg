import Foundation

/// Calls the Anthropic Messages API directly with the user's key.
struct ClaudeClient {
    let apiKey: String
    let model: String

    struct Message: Codable, Hashable {
        let role: String   // "user" | "assistant"
        let content: String
    }

    static let models: [(id: String, name: String)] = [
        ("claude-sonnet-5-5", "Sonnet 5.5 · balanced"),
        ("claude-opus-5-5", "Opus 5.5 · deepest"),
        ("claude-haiku-5-5", "Haiku 5.5 · cheapest")
    ]

    func send(system: String, messages: [Message], maxTokens: Int = 2500) async throws -> String {
        guard !apiKey.isEmpty else { throw APIError.missingKey("Claude") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            // The big data context lives in the system prompt and is cached, so follow-up questions are cheap.
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }

        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let text = r.content.compactMap(\.text).joined(separator: "\n")
        guard !text.isEmpty else { throw APIError.badResponse }
        return text
    }
}
