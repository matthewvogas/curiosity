import Foundation

/// La biblioteca de robots en disco: los incluidos en la app y los importados por la persona.
enum RobotQueries {
    private static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var libraryFile: URL { folder.appendingPathComponent("robots.json") }

    /// Robots que vienen con la app (resources/robots/<id>/<id>.urdf + <id>.studio.json).
    static func bundled() -> [Robot] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("robots"),
              let ids = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return ids.sorted().compactMap { id in
            let urdf = "robots/\(id)/\(id).urdf"
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/\(id).urdf").path) else { return nil }
            let profile = readProfile(urdfURL: root.appendingPathComponent("\(id)/\(id).urdf"))
            return Robot(id: "bundled.\(id)", name: profile["name"] as? String ?? id,
                         summary: profile["description"] as? String ?? "", source: .bundled,
                         urdfPath: urdf, license: profile["license"] as? String, addedAt: .distantPast)
        }
    }

    /// Robots importados (guardados en Application Support/Curiosity/robots.json).
    static func imported() -> [Robot] {
        guard let data = try? Data(contentsOf: libraryFile) else { return [] }
        return (try? JSONDecoder().decode([Robot].self, from: data)) ?? []
    }

    static func saveImported(_ robots: [Robot]) throws {
        let data = try JSONEncoder().encode(robots)
        try data.write(to: libraryFile, options: .atomic)
    }

    /// El URDF del archivo en disco del robot (para leer su perfil o mostrarlo en Finder).
    static func fileURL(for robot: Robot) -> URL? {
        switch robot.source {
        case .bundled: Bundle.main.resourceURL?.appendingPathComponent(robot.urdfPath)
        case .file, .library: URL(fileURLWithPath: robot.urdfPath)
        }
    }

    /// Perfil opcional junto al URDF (<nombre>.studio.json): cámaras, actuadores, escena inicial.
    static func readProfile(urdfURL: URL) -> [String: Any] {
        let profile = urdfURL.deletingPathExtension().appendingPathExtension("studio.json")
        guard let data = try? Data(contentsOf: profile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    // MARK: - Keyframes (por robot, en Application Support/Curiosity/keyframes/<id>.json)

    private static func keyframesFile(_ robotID: String) -> URL {
        let dir = folder.appendingPathComponent("keyframes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = robotID.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }

    static func keyframes(robotID: String) -> [Keyframe] {
        guard let data = try? Data(contentsOf: keyframesFile(robotID)) else { return [] }
        return (try? JSONDecoder().decode([Keyframe].self, from: data)) ?? []
    }

    static func saveKeyframes(_ keys: [Keyframe], robotID: String) throws {
        try JSONEncoder().encode(keys).write(to: keyframesFile(robotID), options: .atomic)
    }

    /// Guarda una captura de pantalla en Imágenes/Curiosity y devuelve dónde quedó.
    static func saveScreenshot(_ png: Data, robotName: String) throws -> URL {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        let url = dir.appendingPathComponent("\(robotName) \(stamp).png")
        try png.write(to: url)
        return url
    }

    /// Nombre del robot según el propio archivo: <robot name="…"> (URDF) o <mujoco model="…"> (MJCF).
    /// nil si no es ninguno de los dos.
    static func modelName(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for pattern in [#"<robot[^>]*\sname\s*=\s*"([^"]+)""#, #"<mujoco[^>]*\smodel\s*=\s*"([^"]+)""#] {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range]).components(separatedBy: "\"").dropFirst().first
            }
        }
        if text.contains("<mujoco") { return url.deletingPathExtension().lastPathComponent }
        return nil
    }
}
