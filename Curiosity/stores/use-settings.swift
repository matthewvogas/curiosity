import SwiftUI
import Observation

/// Ajustes: la IA (API key en el Llavero y modelo), LeRobot (su Python) y Hugging Face (token en el Llavero).
@Observable
final class UseSettings {
    private static let anthropicAccount = "anthropic-api-key"
    private static let hubAccount = "huggingface-token"

    /// El Python donde está instalado LeRobot (el de su entorno virtual).
    var lerobotPython: String { didSet { UserDefaults.standard.set(lerobotPython, forKey: "lerobot.python") } }
    private(set) var hasHubToken = false

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
        // La primera vez se busca solo; si no aparece, se indica en Ajustes.
        lerobotPython = UserDefaults.standard.string(forKey: "lerobot.python") ?? PythonQueries.findLeRobot() ?? ""
        hasHubToken = KeychainQueries.read(Self.hubAccount) != nil
    }

    var hubToken: String? { KeychainQueries.read(Self.hubAccount) }

    func saveHubToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KeychainQueries.save(Self.hubAccount, value: trimmed)
        hasHubToken = true
    }

    func removeHubToken() {
        KeychainQueries.delete(Self.hubAccount)
        hasHubToken = false
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
