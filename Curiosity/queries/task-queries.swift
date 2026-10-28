import Foundation

/// Las tareas guardadas (Application Support/Curiosity/tasks.json).
enum TaskQueries {
    private static var file: URL { AppPaths.root.appendingPathComponent("tasks.json") }

    static func load() -> [TeachTask] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([TeachTask].self, from: data)) ?? []
    }

    static func save(_ tasks: [TeachTask]) {
        try? JSONEncoder().encode(tasks).write(to: file, options: .atomic)
    }
}
