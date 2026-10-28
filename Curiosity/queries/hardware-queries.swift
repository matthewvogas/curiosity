import Foundation

/// La configuración del robot físico de cada modelo (Application Support/Curiosity/hardware/<id>.json).
enum HardwareQueries {
    private static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity/hardware", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ robotID: String) -> URL {
        folder.appendingPathComponent(robotID.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    static func load(robotID: String) -> HardwareProfile? {
        guard let data = try? Data(contentsOf: file(robotID)) else { return nil }
        return try? JSONDecoder().decode(HardwareProfile.self, from: data)
    }

    static func save(_ profile: HardwareProfile, robotID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: file(robotID), options: .atomic)
    }
}
