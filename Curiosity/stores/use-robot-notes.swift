import Foundation
import Observation

/// Las notas del robot abierto (pestaña «Notes»): las de la persona, que se guardan solas al escribir, y lo que
/// aprendió la IA, que se puede borrar. El chat las lee del archivo en cada mensaje.
@Observable
final class UseRobotNotes {
    private(set) var robotID = ""
    private(set) var notes = ""
    private(set) var learned: [String] = []
    private var saveTask: Task<Void, Never>?

    func open(_ robotID: String) {
        guard robotID != self.robotID else { reload(); return }
        flush()
        self.robotID = robotID
        reload()
    }

    /// Vuelve a leer el archivo (p. ej. después de que la IA guardó una lección).
    func reload() {
        guard !robotID.isEmpty else { return }
        let file = RobotNotesQueries.load(robotID)
        if saveTask == nil { notes = file.notes }
        learned = file.learned
    }

    /// Lo que escribe la persona: se guarda medio segundo después de la última tecla.
    func setNotes(_ text: String) {
        notes = text
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func removeLesson(_ index: Int) {
        guard learned.indices.contains(index) else { return }
        // Lo último del archivo, por si la IA agregó algo mientras tanto.
        var current = RobotNotesQueries.load(robotID).learned
        if let i = current.firstIndex(of: learned[index]) { current.remove(at: i) }
        learned = current
        RobotNotesQueries.save(robotID, notes: notes, learned: learned)
    }

    func reveal() { flush(); RobotNotesQueries.reveal(robotID) }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard !robotID.isEmpty else { return }
        RobotNotesQueries.save(robotID, notes: notes, learned: RobotNotesQueries.load(robotID).learned)
    }
}
