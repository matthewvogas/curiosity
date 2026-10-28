import Foundation

/// Conversaciones guardadas, una por archivo: Application Support/Curiosity/chats/<robot>/<id>.json.
enum ChatQueries {
    private static func folder(_ robotID: String) -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity/chats", isDirectory: true)
            .appendingPathComponent(robotID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ robotID: String, _ id: UUID) -> URL {
        folder(robotID).appendingPathComponent("\(id.uuidString).json")
    }

    /// Las conversaciones de un robot, la más reciente primero.
    static func list(robotID: String) -> [ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(robotID), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Conversation.self, from: data) else { return nil }
            return ConversationSummary(id: c.id, title: c.title, updatedAt: c.updatedAt)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func load(robotID: String, id: UUID) -> Conversation? {
        guard let data = try? Data(contentsOf: file(robotID, id)) else { return nil }
        return try? JSONDecoder().decode(Conversation.self, from: data)
    }

    static func save(_ conversation: Conversation) throws {
        try JSONEncoder().encode(conversation).write(to: file(conversation.robotID, conversation.id), options: .atomic)
    }

    static func delete(robotID: String, id: UUID) {
        try? FileManager.default.removeItem(at: file(robotID, id))
    }
}
