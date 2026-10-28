import SwiftUI
import Observation

/// Ajustes de IA: la API key (en el Llavero) y qué modelo usar.
@Observable
final class UseSettings {
    private static let anthropicAccount = "anthropic-api-key"

    private(set) var hasAnthropicKey = false
    var modelID: String { didSet { UserDefaults.standard.set(modelID, forKey: "ai.model") } }
    /// Cuánto piensa el modelo: low · medium · high.
    var effort: String { didSet { UserDefaults.standard.set(effort, forKey: "ai.effort") } }
    private(set) var testing = false
    private(set) var testResult: (ok: Bool, message: String)?

    init() {
        modelID = UserDefaults.standard.string(forKey: "ai.model") ?? AIModel.all[0].id
        effort = UserDefaults.standard.string(forKey: "ai.effort") ?? "medium"
        hasAnthropicKey = KeychainQueries.read(Self.anthropicAccount) != nil
    }

    var anthropicKey: String? { KeychainQueries.read(Self.anthropicAccount) }

    func saveAnthropicKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainQueries.save(Self.anthropicAccount, value: trimmed)
        hasAnthropicKey = true
        testResult = nil
    }

    func removeAnthropicKey() {
        KeychainQueries.delete(Self.anthropicAccount)
        hasAnthropicKey = false
        testResult = nil
    }

    /// Una solicitud mínima para comprobar que la key y el modelo funcionan.
    func testConnection() async {
        guard let key = anthropicKey else { return }
        testing = true
        defer { testing = false }
        do {
            _ = try await AnthropicQueries.createMessage(apiKey: key, body: [
                "model": modelID, "max_tokens": 64,
                "output_config": ["effort": "low"],
                "messages": [["role": "user", "content": "Responde solo: ok"]],
            ])
            testResult = (true, "Conectado")
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}
