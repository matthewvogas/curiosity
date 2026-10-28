import Foundation
import Observation

/// La biblioteca de robots: los incluidos, los importados y cuál está abierto.
@Observable
final class UseRobots {
    private(set) var robots: [Robot] = []
    private(set) var error: String?
    var selectedID: String? { didSet { UserDefaults.standard.set(selectedID, forKey: "robots.selected") } }

    var selected: Robot? { robots.first { $0.id == selectedID } }

    init() {
        load()
        selectedID = UserDefaults.standard.string(forKey: "robots.selected") ?? robots.first?.id
        if selected == nil { selectedID = robots.first?.id }
    }

    func load() {
        robots = RobotQueries.bundled() + RobotQueries.imported().sorted { $0.addedAt > $1.addedAt }
    }

    /// Importa un URDF del disco. Sus mallas se leen desde su carpeta; no se copia nada.
    func importURDF(at url: URL) {
        error = nil
        guard let name = RobotQueries.urdfName(at: url) else {
            error = "Ese archivo no parece un URDF (falta <robot name=…>)."
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

    func remove(_ robot: Robot) {
        guard robot.source == .file else { return }
        let rest = RobotQueries.imported().filter { $0.id != robot.id }
        try? RobotQueries.saveImported(rest)
        load()
        if selectedID == robot.id { selectedID = robots.first?.id }
    }

    func profile(for robot: Robot) -> [String: Any] {
        guard let url = RobotQueries.fileURL(for: robot) else { return [:] }
        return RobotQueries.readProfile(urdfURL: url)
    }
}
