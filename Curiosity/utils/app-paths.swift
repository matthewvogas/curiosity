import Foundation

/// Dónde guarda la app lo que produce con el robot (en Application Support/Curiosity).
enum AppPaths {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func folder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Datasets grabados con la app.
    static var datasets: URL { folder("datasets") }
    /// Modelos entrenados con la app (uno por carpeta).
    static var training: URL { folder("training") }
    /// Registros de los entrenamientos.
    static var logs: URL { folder("logs") }
    /// Donde LeRobot guarda los datasets descargados del Hub.
    static var hubCache: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/lerobot", isDirectory: true)
    }

    /// Nombre válido para un dataset o un entrenamiento.
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_\-]{1,60}$"#, options: .regularExpression) != nil
    }
}
