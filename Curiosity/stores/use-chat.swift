import AppKit
import Observation

/// La conversación con la IA que maneja el robot: manda mensajes, corre las herramientas que la IA
/// pide sobre la simulación y repite hasta que la IA termina.
@Observable
final class UseChat {
    private let settings: UseSettings
    private let simulation: UseSimulation

    private(set) var items: [ChatItem] = []
    private(set) var isRunning = false
    private(set) var error: String?
    /// Conversaciones anteriores con este robot (la más reciente primero).
    private(set) var conversations: [ConversationSummary] = []
    private(set) var conversationID = UUID()

    /// Historia en el formato de la API. Solo se agrega al final (las respuestas van completas,
    /// con sus bloques de pensamiento, como pide la API).
    private var history: [[String: Any]] = []
    private var task: Task<Void, Never>?
    private var robotName = ""
    private var robotID = ""

    private static let maxTurns = 24

    init(settings: UseSettings, simulation: UseSimulation) {
        self.settings = settings
        self.simulation = simulation
    }

    /// Conversación nueva (al cambiar de robot o con «Nueva conversación»). Se guarda al primer mensaje.
    func reset(robotName: String, robotID: String) {
        stop()
        self.robotName = robotName
        self.robotID = robotID
        conversationID = UUID()
        items = []
        history = []
        error = nil
        conversations = ChatQueries.list(robotID: robotID)
    }

    /// Retoma una conversación guardada.
    func open(_ id: UUID) {
        guard let c = ChatQueries.load(robotID: robotID, id: id) else { return }
        stop()
        conversationID = c.id
        items = c.items
        history = (try? JSONSerialization.jsonObject(with: c.history) as? [[String: Any]]) ?? []
        error = nil
    }

    func delete(_ id: UUID) {
        ChatQueries.delete(robotID: robotID, id: id)
        conversations.removeAll { $0.id == id }
        if id == conversationID { reset(robotName: robotName, robotID: robotID) }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        guard let key = settings.anthropicKey else {
            error = "Conecta tu API key en Ajustes para hablar con el robot."
            return
        }
        guard let model = simulation.model else {
            error = "Espera a que el robot termine de cargar."
            return
        }
        error = nil
        items.append(ChatItem(kind: .user(text)))
        history.append(["role": "user", "content": text])
        persist()
        task = Task { await run(apiKey: key, model: model) }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        // Las acciones a medio correr quedan como interrumpidas.
        var interrupted = false
        for i in items.indices {
            if case .action(let title, let detail, true, _) = items[i].kind {
                items[i].kind = .action(title: title, detail: detail, running: false, failed: true)
                interrupted = true
            }
        }
        closeOpenToolUses()
        if interrupted { persist() }
    }

    /// Si se cortó a mitad de una acción, la API necesita su resultado antes del próximo mensaje.
    private func closeOpenToolUses() {
        guard let last = history.last, last["role"] as? String == "assistant",
              let content = last["content"] as? [[String: Any]] else { return }
        let ids = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return }
        history.append(["role": "user", "content": ids.map {
            ["type": "tool_result", "tool_use_id": $0, "content": "Interrumpido por la persona.", "is_error": true] as [String: Any]
        }])
    }

    /// Guarda la conversación (título = el primer mensaje) y actualiza la lista del historial.
    private func persist() {
        guard !robotID.isEmpty, !items.isEmpty else { return }
        let first = items.lazy.compactMap { if case .user(let t) = $0.kind { t } else { nil } }.first ?? "Conversación"
        let title = first.count > 60 ? String(first.prefix(57)) + "…" : first
        let data = (try? JSONSerialization.data(withJSONObject: history)) ?? Data("[]".utf8)
        let conversation = Conversation(id: conversationID, robotID: robotID, title: title, items: items, history: data)
        try? ChatQueries.save(conversation)
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(ConversationSummary(id: conversationID, title: title, updatedAt: conversation.updatedAt), at: 0)
    }

    // MARK: - Bucle con herramientas

    private func run(apiKey: String, model: RobotModel) async {
        isRunning = true
        defer { isRunning = false; persist() }
        let system = AgentTools.systemPrompt(model: model, robotName: robotName)

        for _ in 0..<Self.maxTurns {
            if Task.isCancelled { return }
            let response: [String: Any]
            do {
                var body: [String: Any] = [
                    "model": settings.modelID,
                    "max_tokens": 16000,
                    "system": system,
                    "tools": AgentTools.definitions,
                    "output_config": ["effort": settings.effort],
                    "messages": history,
                ]
                // Si un filtro de seguridad declina, la API reintenta con otro modelo (solo Opus y Sonnet).
                if !settings.modelID.contains("haiku") { body["fallbacks"] = "default" }
                response = try await AnthropicQueries.createMessage(apiKey: apiKey, body: body)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
                return
            }
            if Task.isCancelled { return }

            let content = response["content"] as? [[String: Any]] ?? []
            history.append(["role": "assistant", "content": content])
            for block in content where block["type"] as? String == "text" {
                if let text = block["text"] as? String, !text.isEmpty { items.append(ChatItem(kind: .assistant(text))) }
            }

            switch response["stop_reason"] as? String {
            case "tool_use":
                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    results.append(await execute(block, model: model))
                    if Task.isCancelled { return }
                }
                history.append(["role": "user", "content": results])
            case "refusal":
                items.append(ChatItem(kind: .notice("La IA no puede ayudar con esa solicitud.", isError: true)))
                return
            case "max_tokens":
                items.append(ChatItem(kind: .notice("La respuesta se cortó por largo.", isError: false)))
                return
            default:
                return
            }
        }
        items.append(ChatItem(kind: .notice("Se alcanzó el máximo de pasos seguidos. Pídele que continúe.", isError: false)))
    }

    /// Corre una herramienta y devuelve su tool_result. Muestra el avance en el chat.
    private func execute(_ block: [String: Any], model: RobotModel) async -> [String: Any] {
        let id = block["id"] as? String ?? ""
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        let title = AgentTools.title(for: name, input: input)
        items.append(ChatItem(kind: .action(title: title, detail: "", running: true, failed: false)))
        let index = items.count - 1

        func finish(_ detail: String, failed: Bool = false) {
            if items.indices.contains(index) {
                items[index].kind = .action(title: title, detail: detail, running: false, failed: failed)
            }
        }

        do {
            switch name {
            case "get_state":
                finish("")
                return result(id, text: AgentTools.json(currentState(model)))

            case "move_joints":
                let types = Dictionary(uniqueKeysWithValues: model.joints.map { ($0.name, $0) })
                var unknown: [String] = []
                for t in input["targets"] as? [[String: Any]] ?? [] {
                    guard let joint = t["joint"] as? String, let value = (t["value"] as? NSNumber)?.doubleValue else { continue }
                    guard let info = types[joint], info.actuated else { unknown.append(joint); continue }
                    var v = Units.fromDisplay(value, jointType: info.type)
                    if let lo = info.lower, let hi = info.upper { v = min(hi, max(lo, v)) }
                    simulation.setTarget(joint, v)
                }
                let seconds = min(5, max(0.2, (input["seconds"] as? NSNumber)?.doubleValue ?? 1.5))
                await simulation.run(seconds: seconds)
                finish(unknown.isEmpty ? "" : "Sin motor o no existe: \(unknown.joined(separator: ", "))", failed: !unknown.isEmpty)
                var out = currentState(model)
                if !unknown.isEmpty { out["unknown_joints"] = unknown }
                return result(id, text: AgentTools.json(out))

            case "look":
                let camera = (input["camera"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let jpeg = try await simulation.capture(camera: camera)
                finish("")
                items.append(ChatItem(kind: .image(jpeg)))
                return [
                    "type": "tool_result", "tool_use_id": id,
                    "content": [["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                             "data": jpeg.base64EncodedString()]]],
                ]

            case "add_object":
                let size = Units.meters((input["size_cm"] as? [NSNumber] ?? []).map(\.doubleValue))
                let pos = Units.meters((input["position_cm"] as? [NSNumber] ?? []).map(\.doubleValue))
                let object = SceneObject(id: 0, shape: input["shape"] as? String ?? "box",
                                         size: size.isEmpty ? [0.03, 0.03, 0.03] : size,
                                         mass: ((input["mass_g"] as? NSNumber)?.doubleValue ?? 20) / 1000,
                                         color: input["color"] as? String ?? "#cccccc",
                                         pos: pos.count == 3 ? pos : [0.2, 0, 0.1])
                let newID = try await simulation.addObject(object)
                finish("")
                return result(id, text: AgentTools.json(["id": newID]))

            case "remove_object":
                simulation.removeObject((input["id"] as? NSNumber)?.intValue ?? -1)
                finish("")
                return result(id, text: "ok")

            case "reset":
                simulation.reset()
                await simulation.run(seconds: 0.3)
                finish("")
                return result(id, text: AgentTools.json(currentState(model)))

            default:
                finish("Herramienta desconocida", failed: true)
                return result(id, text: "Herramienta desconocida: \(name)", isError: true)
            }
        } catch {
            finish(error.localizedDescription, failed: true)
            return result(id, text: error.localizedDescription, isError: true)
        }
    }

    private func currentState(_ model: RobotModel) -> [String: Any] {
        AgentTools.describe(state: simulation.state, model: model, objects: simulation.objects)
    }

    private func result(_ id: String, text: String, isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
        if isError { r["is_error"] = true }
        return r
    }
}
