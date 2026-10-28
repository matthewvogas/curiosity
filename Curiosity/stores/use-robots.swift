import Foundation
import Observation

/// Mis robots para simular: empieza vacía; se agregan el incluido, los de la biblioteca o un archivo.
@Observable
final class UseRobots {
    private(set) var robots: [Robot] = []
    private(set) var error: String?
    var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "robots.selected") } }

    var selected: Robot? { robots.first { $0.id == selectedID } }
    /// Los robots que vienen con la app (para el catálogo de «Abrir simulador»).
    let included: [Robot] = RobotQueries.bundled()

    init() {
        load()
        selectedID = UserDefaults.standard.string(forKey: "robots.selected")
        if selected == nil { selectedID = nil }
    }

    func load() {
        robots = RobotQueries.imported().sorted { $0.addedAt > $1.addedAt }
    }

    /// Agrega (o abre, si ya estaba) un robot incluido en la app.
    func addIncluded(_ robot: Robot) {
        var mine = RobotQueries.imported()
        if !mine.contains(where: { $0.id == robot.id }) {
            var added = robot
            added.addedAt = .now
            mine.append(added)
            do { try RobotQueries.saveImported(mine) } catch {
                self.error = "No se pudo guardar la lista: \(error.localizedDescription)"
                return
            }
            load()
        }
        selectedID = robot.id
    }

    /// Importa un URDF o MJCF del disco. Sus mallas se leen desde su carpeta; no se copia nada.
    func importModel(at url: URL) {
        error = nil
        guard let name = RobotQueries.modelName(at: url) else {
            error = "Ese archivo no parece un URDF ni un MJCF."
            return
        }
        let profile = RobotQueries.readProfile(urdfURL: url)
        var imported = RobotQueries.imported()
        if let existing = imported.first(where: { $0.urdfPath == url.path }) {
            selectedID = existing.id
            return
        }
        let robot = Robot(id: UUID().uuidString, name: profile["name"] as? String ?? name,
                          summary: profile["description"] as? String ?? url.deletingLastPathComponent().lastPathComponent,
                          source: .file, urdfPath: url.path, license: profile["license"] as? String, addedAt: .now)
        imported.append(robot)
        do {
            try RobotQueries.saveImported(imported)
            load()
            selectedID = robot.id
        } catch {
            self.error = "No se pudo guardar la biblioteca: \(error.localizedDescription)"
        }
    }

    /// Un robot recién descargado de la biblioteca: se agrega (o se reabre si ya estaba).
    func addFromLibrary(id: String, name: String, category: String, modelURL: URL) {
        var imported = RobotQueries.imported()
        if !imported.contains(where: { $0.id == id }) {
            imported.append(Robot(id: id, name: name, summary: category, source: .library, urdfPath: modelURL.path,
                                  license: "MuJoCo Menagerie", addedAt: .now))
            do { try RobotQueries.saveImported(imported) } catch {
                self.error = "No se pudo guardar la biblioteca: \(error.localizedDescription)"
                return
            }
            load()
        }
        selectedID = id
    }

    /// Lo quita de la lista (los archivos descargados se quedan en el disco).
    func remove(_ robot: Robot) {
        let rest = RobotQueries.imported().filter { $0.id != robot.id }
        try? RobotQueries.saveImported(rest)
        load()
        if selectedID == robot.id { selectedID = nil }
    }

    func profile(for robot: Robot) -> [String: Any] {
        guard let url = RobotQueries.fileURL(for: robot) else { return [:] }
        return RobotQueries.readProfile(urdfURL: url)
    }
}
