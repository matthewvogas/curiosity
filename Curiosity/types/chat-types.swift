import Foundation

/// Un renglón de la conversación tal como se muestra (la historia para la API va aparte).
struct ChatItem: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case user(String)
        case assistant(String)
        /// Una acción de la IA sobre el robot.
        case action(title: String, detail: String, running: Bool, failed: Bool)
        /// Lo que la IA miró (JPEG).
        case image(Data)
        case notice(String, isError: Bool)
        /// Un movimiento del robot real que la persona debe aprobar antes de que ocurra.
        case approval(title: String, detail: String, state: ApprovalState)
    }

    enum ApprovalState: String, Codable { case pending, approved, rejected }

    var id = UUID()
    var kind: Kind
}

/// Con qué habla la IA: el robot simulado o el real. Da las herramientas, el prompt y las corre.
protocol ChatBody: AnyObject {
    var chatTools: [[String: Any]] { get }
    /// nil mientras el robot no está listo para conversar (cargando, desconectado…).
    func chatSystemPrompt(robotName: String) -> String?
    var chatNotReady: String { get }
    func chatTitle(_ name: String, _ input: [String: Any]) -> String
    /// Lo que la persona tiene que aprobar antes de correr la herramienta (nil: no hace falta).
    func chatApproval(_ name: String, _ input: [String: Any]) -> String?
    func chatRun(_ name: String, _ input: [String: Any]) async throws -> ChatToolOutput
}

/// Lo que devuelve una herramienta: texto para la IA (y un aviso si algo no salió), o una imagen.
enum ChatToolOutput {
    case text(String, problem: String? = nil)
    case image(Data)
}

/// Una conversación guardada con un robot: lo que se ve y la historia para seguirla con la API.
struct Conversation: Identifiable, Codable {
    var id = UUID()
    var robotID: String
    var title: String
    var updatedAt = Date()
    var items: [ChatItem] = []
    /// Mensajes en el formato de la API (JSON), para continuar donde quedó.
    var history: Data = Data("[]".utf8)
}

/// Para la lista del historial (sin cargar los mensajes).
struct ConversationSummary: Identifiable, Equatable {
    var id: UUID
    var title: String
    var updatedAt: Date
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
