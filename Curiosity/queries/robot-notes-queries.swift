import AppKit

/// Las notas de cada robot en robot-notes/<robot>.md (ver RobotNotes): se pueden abrir con cualquier editor.
enum RobotNotesQueries {
    static func url(_ robotID: String) -> URL { AppPaths.robotNotes.appendingPathComponent(RobotNotes.fileName(robotID)) }

    static func load(_ robotID: String) -> (notes: String, learned: [String]) {
        RobotNotes.parse((try? String(contentsOf: url(robotID), encoding: .utf8)) ?? "")
    }

    static func save(_ robotID: String, notes: String, learned: [String]) {
        guard !robotID.isEmpty else { return }
        try? RobotNotes.format(notes: notes, learned: learned).write(to: url(robotID), atomically: true, encoding: .utf8)
    }

    /// Muestra el archivo en el Finder (lo crea vacío si todavía no existe).
    static func reveal(_ robotID: String) {
        let file = url(robotID)
        if !FileManager.default.fileExists(atPath: file.path) { save(robotID, notes: "", learned: []) }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
