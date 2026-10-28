import AppKit
import Observation

/// La conversación con la IA que maneja un robot (simulado o real, según su `ChatBody`): manda mensajes,
/// corre las herramientas que la IA pide y repite hasta que termina. Lo que mueve un robot real espera
/// a que la persona lo apruebe en el chat.
@Observable
final class UseChat {
    private let settings: UseSettings
    private let body: ChatBody
    /// La aprobación que se está esperando (se responde con approve / reject).
    private var waitingApproval: CheckedContinuation<Bool, Never>?

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
    private(set) var robotID = ""

    private static let maxTurns = 24

    init(settings: UseSettings, body: ChatBody) {
        self.settings = settings
        self.body = body
    }

    func approve() { answer(true) }
    func reject() { answer(false) }

    private func answer(_ ok: Bool) {
        waitingApproval?.resume(returning: ok)
        waitingApproval = nil
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
            error = "Add your API key in Settings to talk to the robot."
            return
        }
        guard let system = body.chatSystemPrompt(robotName: robotName) else {
            error = body.chatNotReady
            return
        }
        error = nil
        items.append(ChatItem(kind: .user(text)))
        history.append(["role": "user", "content": text])
        persist()
        task = Task { await run(apiKey: key, system: system) }
    }

    func stop() {
        answer(false)
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
            if case .approval(let title, let detail, .pending) = items[i].kind {
                items[i].kind = .approval(title: title, detail: detail, state: .rejected)
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
            ["type": "tool_result", "tool_use_id": $0, "content": "Interrupted by the user.", "is_error": true] as [String: Any]
        }])
    }

    /// Guarda la conversación (título = el primer mensaje) y actualiza la lista del historial.
    private func persist() {
        guard !robotID.isEmpty, !items.isEmpty else { return }
        let first = items.lazy.compactMap { if case .user(let t) = $0.kind { t } else { nil } }.first ?? "Conversation"
        let title = first.count > 60 ? String(first.prefix(57)) + "…" : first
        let data = (try? JSONSerialization.data(withJSONObject: history)) ?? Data("[]".utf8)
        let conversation = Conversation(id: conversationID, robotID: robotID, title: title, items: items, history: data)
        try? ChatQueries.save(conversation)
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(ConversationSummary(id: conversationID, title: title, updatedAt: conversation.updatedAt), at: 0)
    }

    // MARK: - Bucle con herramientas

    private func run(apiKey: String, system: String) async {
        isRunning = true
        defer { isRunning = false; persist() }

        for _ in 0..<Self.maxTurns {
            if Task.isCancelled { return }
            let response: [String: Any]
            do {
                var body: [String: Any] = [
                    "model": settings.modelID,
                    "max_tokens": 16000,
                    "system": system,
                    "tools": body.chatTools,
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
                    results.append(await execute(block))
                    if Task.isCancelled { return }
                }
                history.append(["role": "user", "content": results])
            case "refusal":
                items.append(ChatItem(kind: .notice("The AI can't help with that request.", isError: true)))
                return
            case "max_tokens":
                items.append(ChatItem(kind: .notice("The reply was cut off for length.", isError: false)))
                return
            default:
                return
            }
        }
        items.append(ChatItem(kind: .notice("Reached the maximum number of steps in a row. Ask it to continue.", isError: false)))
    }

    /// Corre una herramienta y devuelve su tool_result. Muestra el avance en el chat y, si mueve un robot
    /// real, antes espera la aprobación de la persona.
    private func execute(_ block: [String: Any]) async -> [String: Any] {
        let id = block["id"] as? String ?? ""
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        let title = body.chatTitle(name, input)

        if let detail = body.chatApproval(name, input) {
            items.append(ChatItem(kind: .approval(title: title, detail: detail, state: .pending)))
            let index = items.count - 1
            let ok = await withCheckedContinuation { waitingApproval = $0 }
            if items.indices.contains(index) {
                items[index].kind = .approval(title: title, detail: detail, state: ok ? .approved : .rejected)
            }
            guard ok else {
                return result(id, text: "The user didn't approve this move. Ask them what they'd prefer.", isError: true)
            }
        }

        items.append(ChatItem(kind: .action(title: title, detail: "", running: true, failed: false)))
        let index = items.count - 1
        func finish(_ detail: String, failed: Bool = false) {
            if items.indices.contains(index) {
                items[index].kind = .action(title: title, detail: detail, running: false, failed: failed)
            }
        }

        do {
            switch try await body.chatRun(name, input) {
            case .text(let text, let problem):
                finish(problem ?? "", failed: problem != nil)
                return result(id, text: text)
            case .images(let photos):
                finish("")
                var content: [[String: Any]] = []
                for photo in photos {
                    items.append(ChatItem(kind: .image(photo.jpeg)))
                    if !photo.label.isEmpty { content.append(["type": "text", "text": "Camera \"\(photo.label)\":"]) }
                    content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                                "data": photo.jpeg.base64EncodedString()]])
                }
                return ["type": "tool_result", "tool_use_id": id, "content": content]
            }
        } catch {
            finish(error.localizedDescription, failed: true)
            return result(id, text: error.localizedDescription, isError: true)
        }
    }

    private func result(_ id: String, text: String, isError: Bool = false) -> [String: Any] {
        var r: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
        if isError { r["is_error"] = true }
        return r
    }
}
