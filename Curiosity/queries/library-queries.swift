import Foundation

/// La biblioteca de MuJoCo Menagerie: el catálogo incluido en la app y la descarga de cada robot
/// (desde GitHub, en la versión fija del catálogo) a Application Support/Curiosity/library.
enum LibraryQueries {
    static func catalog() -> LibraryCatalog? {
        guard let url = Bundle.main.url(forResource: "menagerie", withExtension: "json", subdirectory: "library"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryCatalog.self, from: data)
    }

    static func rawURL(_ catalog: LibraryCatalog, _ path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/\(catalog.source)/\(catalog.commit)/\(path)")!
    }

    private static func folder(_ catalog: LibraryCatalog) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity/library/\(catalog.commit.prefix(12))", isDirectory: true)
    }

    /// Dónde queda el MJCF del robot una vez descargado.
    static func localModel(_ catalog: LibraryCatalog, _ robot: LibraryRobot) -> URL {
        folder(catalog).appendingPathComponent(robot.xml)
    }

    /// Descarga los archivos que falten (8 a la vez). `progress` recibe la fracción descargada.
    static func download(_ catalog: LibraryCatalog, _ robot: LibraryRobot,
                         progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let root = folder(catalog)
        let missing = robot.files.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        let total = max(missing.count, 1)
        var done = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = missing[...]
            func next() {
                guard let path = queue.popFirst() else { return }
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(from: rawURL(catalog, path))
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw NSError(domain: "Curiosity", code: 3, userInfo: [NSLocalizedDescriptionKey: "No se pudo descargar \(path)."])
                    }
                    let dest = root.appendingPathComponent(path)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: dest, options: .atomic)
                }
            }
            for _ in 0..<8 { next() }
            while try await group.next() != nil {
                done += 1
                progress(Double(done) / Double(total))
                next()
            }
        }
        return localModel(catalog, robot)
    }
}
