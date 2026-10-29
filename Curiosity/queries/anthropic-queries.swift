import Foundation

/// Llamadas a la API de Claude (Messages API, HTTP directo: no hay SDK oficial para Swift).
/// Devuelven la respuesta cruda; no guardan estado ni la transforman.
enum AnthropicQueries {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    struct APIError: LocalizedError {
        var status: Int
        var message: String
        var errorDescription: String? {
            switch status {
            case 401: "The API key isn't valid. Check it in Settings."
            case 429: "Too many requests right now. Wait a moment and try again."
            case 529, 500...599: "Claude isn't responding right now. Try again."
            default: message
            }
        }
    }

    /// POST /v1/messages. `body` es el JSON de la solicitud (model, messages, tools, …).
    static func createMessage(apiKey: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // Si un filtro de seguridad declina, la API reintenta con otro modelo en la misma llamada.
        // Reintento con otro modelo si un filtro declina; y poder pedir que se descarten pensamientos viejos
        // cuyo contexto cambió (thinking.block_binding) en lugar de fallar.
        request.setValue("server-side-fallback-2026-07-01,thinking-binding-controls-2026-08-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Error \(status)"
            throw APIError(status: status, message: message)
        }
        return json
    }
}
