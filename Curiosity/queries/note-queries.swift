import AppKit

/// Las notas de cada tarea: un documento con formato (RTF) en notes/<id>.rtf, que también abre TextEdit o Word.
enum NoteQueries {
    static func url(for task: UUID) -> URL { AppPaths.notes.appendingPathComponent("\(task.uuidString).rtf") }

    static func load(_ url: URL) -> NSAttributedString {
        if let data = try? Data(contentsOf: url),
           let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                              documentAttributes: nil) {
            return text
        }
        return NSAttributedString()
    }

    static func save(_ text: NSAttributedString, to url: URL) {
        let range = NSRange(location: 0, length: text.length)
        guard let data = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
