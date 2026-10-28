import Foundation

/// Los paquetes de conocimiento en disco: Application Support/Curiosity/knowledge/<id>.json.
enum KnowledgeQueries {
    private static var folder: URL { AppPaths.knowledge }

    static func list() -> [KnowledgePackage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(KnowledgePackage.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ package: KnowledgePackage) throws {
        try JSONEncoder().encode(package).write(to: folder.appendingPathComponent("\(package.id.uuidString).json"), options: .atomic)
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
    }
}
