import Foundation
import Observation

/// Paquetes de conocimiento: la IA estudia demostraciones (de esta Mac o de Hugging Face) y escribe cómo se
/// hace la tarea. El paquete activo se usa en vivo, sin entrenar nada.
@Observable
final class UseKnowledge {
    private let settings: UseSettings
    private let lerobot: UseLeRobot

    private(set) var packages: [KnowledgePackage] = KnowledgeQueries.list()
    /// Qué está haciendo el estudio ahora («Bajando las demostraciones…»), o nil.
    private(set) var studying: String?
    private(set) var error: String?
    var activeID: UUID? {
        didSet { UserDefaults.standard.set(activeID?.uuidString, forKey: "knowledge.active") }
    }

    init(settings: UseSettings, lerobot: UseLeRobot) {
        self.settings = settings
        self.lerobot = lerobot
        activeID = UserDefaults.standard.string(forKey: "knowledge.active").flatMap(UUID.init)
    }

    var active: KnowledgePackage? { packages.first { $0.id == activeID } }

    /// Estudia un dataset (`root` para los de esta Mac; sin él se baja del Hub solo lo necesario).
    func study(repoID: String, root: String?, followerID: String?) async {
        guard studying == nil else { return }
        guard let key = settings.anthropicKey else { error = "Conecta tu API key en Ajustes."; return }
        error = nil
        studying = root == nil ? "Bajando unas demostraciones de Hugging Face…" : "Leyendo las demostraciones…"
        defer { studying = nil }
        do {
            if lerobot.status != .ready { await lerobot.start() }
            var args: [String: Any] = ["repo_id": repoID, "episodes": 6]
            if let root { args["root"] = root }
            if let followerID { args["follower_id"] = followerID }
            let material = Self.material(try await lerobot.request("study", args), repoID: repoID)
            guard !material.episodes.isEmpty else { throw Self.fail("El dataset no tiene demostraciones legibles.") }

            studying = "Estudiando \(material.episodes.count) demostraciones…"
            let response = try await AnthropicQueries.createMessage(apiKey: key, body: [
                "model": settings.modelID,
                "max_tokens": 8000,
                "system": KnowledgePrompt.studySystem,
                "tools": [KnowledgePrompt.writePackage],
                "tool_choice": ["type": "tool", "name": "write_package"],
                "messages": [["role": "user", "content": KnowledgePrompt.studyMessage(material)]],
            ])
            guard let input = (response["content"] as? [[String: Any]] ?? [])
                .first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
                throw Self.fail("La IA no escribió el paquete.")
            }
            let package = KnowledgePrompt.package(from: input, material: material)
            try KnowledgeQueries.save(package)
            packages.insert(package, at: 0)
            activeID = package.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ id: UUID) {
        KnowledgeQueries.delete(id)
        packages.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    private static func material(_ r: [String: Any], repoID: String) -> StudyMaterial {
        let episodes = (r["episodes"] as? [[String: Any]] ?? []).map { e in
            StudyMaterial.Episode(index: (e["episode"] as? NSNumber)?.intValue ?? 0, task: e["task"] as? String ?? "",
                                  duration: (e["duration_s"] as? NSNumber)?.doubleValue ?? 0,
                                  trajectory: (e["trajectory"] as? [[NSNumber]] ?? []).map { $0.map(\.doubleValue) },
                                  events: e["gripper_events"] as? [[String: Any]] ?? [])
        }
        let pictures = (r["keyframes"] as? [[String: Any]] ?? []).compactMap { k -> (episode: Int, label: String, jpeg: Data)? in
            guard let d = (k["jpeg"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return ((k["episode"] as? NSNumber)?.intValue ?? 0, k["label"] as? String ?? "", d)
        }
        return StudyMaterial(repoID: repoID, info: r, episodes: episodes, pictures: pictures)
    }

    private static func fail(_ text: String) -> NSError {
        NSError(domain: "Curiosity", code: 10, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
