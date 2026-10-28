import AppKit

/// Un renglón de la conversación tal como se muestra (la historia para la API va aparte).
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(String)
        case assistant(String)
        /// Una acción de la IA sobre el robot: qué hizo y, si miró, la imagen que vio.
        case action(title: String, detail: String, running: Bool, failed: Bool)
        case image(NSImage)
        case notice(String, isError: Bool)
    }

    let id = UUID()
    var kind: Kind
}

/// Modelos de IA disponibles para conversar con el robot.
struct AIModel: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String

    static let all: [AIModel] = [
        AIModel(id: "claude-opus-5-5", name: "Claude Opus 5.5", detail: "El más capaz para planear tareas"),
        AIModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", detail: "Rápido y capaz"),
        AIModel(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", detail: "El más rápido y económico"),
    ]
}
