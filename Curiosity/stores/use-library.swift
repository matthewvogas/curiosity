import Foundation
import Observation

/// La biblioteca de robots de MuJoCo Menagerie: buscar, filtrar y agregar (descargar) a mis robots.
@Observable
final class UseLibrary {
    private let robots: UseRobots
    let catalog: LibraryCatalog?

    var search = ""
    var category: String?
    private(set) var downloading: [String: Double] = [:]
    private(set) var error: String?

    init(robots: UseRobots) {
        self.robots = robots
        catalog = LibraryQueries.catalog()
    }

    var categories: [String] {
        var seen: [String] = []
        for r in catalog?.robots ?? [] where !seen.contains(r.category) { seen.append(r.category) }
        return seen
    }

    var visible: [LibraryRobot] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return (catalog?.robots ?? []).filter { r in
            (category == nil || r.category == category) &&
            (q.isEmpty || r.name.lowercased().contains(q) || r.id.lowercased().contains(q))
        }
    }

    func imageURL(_ robot: LibraryRobot) -> URL? {
        guard let catalog, let image = robot.image else { return nil }
        return LibraryQueries.rawURL(catalog, image)
    }

    /// Se agregó algún robot en esta visita a la biblioteca (para cerrar la hoja de «Agregar»).
    private(set) var isAddedAny = false

    func beginVisit() { isAddedAny = false; error = nil }

    func isAdded(_ robot: LibraryRobot) -> Bool {
        robots.robots.contains { $0.id == "library.\(robot.id)" }
    }

    /// Descarga el robot (si hace falta) y lo agrega a mis robots, ya abierto.
    func add(_ robot: LibraryRobot) async {
        guard let catalog, downloading[robot.id] == nil else { return }
        error = nil
        downloading[robot.id] = 0
        defer { downloading[robot.id] = nil }
        do {
            let url = try await LibraryQueries.download(catalog, robot) { [weak self] p in self?.downloading[robot.id] = p }
            robots.addFromLibrary(id: "library.\(robot.id)", name: robot.name, category: robot.category, modelURL: url)
            isAddedAny = true
        } catch {
            self.error = "No se pudo descargar \(robot.name): \(error.localizedDescription)"
        }
    }
}
