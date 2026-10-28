import Foundation
import Observation

/// Las tareas que se le enseñan a cada robot real y cuál está abierta.
@Observable
final class UseTasks {
    private(set) var tasks: [TeachTask] = TaskQueries.load()
    /// La tarea abierta; sin ninguna, se ve el resumen del robot.
    var selectedID: UUID?
    /// El robot para el que se está escribiendo una tarea nueva (abre la hoja).
    var composingFor: String?

    func tasks(for deviceID: String) -> [TeachTask] {
        tasks.filter { $0.deviceID == deviceID }.sorted { $0.createdAt > $1.createdAt }
    }

    func selected(for deviceID: String) -> TeachTask? {
        let mine = tasks(for: deviceID)
        return mine.first { $0.id == selectedID }
    }

    /// Una tarea nueva: su dataset se nombra a partir de lo que debe hacer.
    @discardableResult
    func add(title: String, deviceID: String) -> TeachTask {
        let taken = Set(tasks.map(\.dataset))
            .union((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.datasets.path)) ?? [])
        let task = TeachTask(deviceID: deviceID, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                             dataset: Naming.unique(Naming.slug(title), taken: taken))
        tasks.append(task)
        TaskQueries.save(tasks)
        selectedID = task.id
        return task
    }

    func update(_ id: UUID, _ change: (inout TeachTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        TaskQueries.save(tasks)
    }

    /// Quita la tarea de la lista (su dataset y su modelo se quedan en el disco).
    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        TaskQueries.save(tasks)
        if selectedID == id { selectedID = nil }
    }
}
