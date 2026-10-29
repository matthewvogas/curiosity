import Foundation

/// El «ROBOT.md» de cada robot, como el CLAUDE.md de un proyecto: lo que la app mide del robot, las notas de la
/// persona y lo que la IA aprendió, en un .md que entra en cada conversación. Solo formato y armado (puro).
///
/// Archivo: las notas en Markdown libre y, al final, «## Learned» con una lección por renglón («- …»).
enum RobotNotes {
    static let learnedHeading = "## Learned"
    static let maxLessons = 15
    static let maxNotes = 6000

    /// El nombre de archivo para un robot (sim: el id del robot; en vivo: «device-<puerto>»).
    static func fileName(_ robotID: String) -> String {
        String(robotID.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || "._-".contains($0) ? $0 : "_" }) + ".md"
    }

    static func parse(_ text: String) -> (notes: String, learned: [String]) {
        let lines = text.components(separatedBy: "\n")
        guard let cut = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == learnedHeading }) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let notes = lines[..<cut].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let learned = lines[(cut + 1)...].compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            let lesson = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return lesson.isEmpty ? nil : lesson
        }
        return (notes, learned)
    }

    static func format(notes: String, learned: [String]) -> String {
        let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learned.isEmpty else { return body + "\n" }
        return body + "\n\n" + learnedHeading + "\n" + learned.map { "- \($0)\n" }.joined()
    }

    /// Agrega una lección (sin repetir, las últimas 15). Devuelve la lista y si la agregó.
    static func adding(_ lesson: String, to learned: [String]) -> ([String], Bool) {
        let t = lesson.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !learned.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return (learned, false) }
        return (Array((learned + [t]).suffix(maxLessons)), true)
    }

    /// Lo que va al final del prompt del sistema.
    static func promptSection(facts: [String]?, notes: String, learned: [String]) -> String {
        var out = "\n\n# About this robot"
        if let facts, !facts.isEmpty { out += "\nMeasured by the app:\n" + facts.joined(separator: "\n") }
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty {
            out += "\n\nNotes from the user (follow them):\n" + (n.count > maxNotes ? String(n.prefix(maxNotes)) + "\n…(cut)" : n)
        }
        if !learned.isEmpty { out += "\n\nLearned in earlier sessions:\n" + learned.map { "- \($0)" }.joined(separator: "\n") }
        out += "\n\nWhen you learn something lasting about this robot, its table or its objects (not a one-off result), "
            + "save it with remember, in one short line. Don't repeat what's already here."
        return out
    }

    /// Los datos medidos: el brazo y la pinza (de `studio.effector()` del motor) y las cámaras, ya descritas.
    static func facts(effector e: [String: Any]?, cameras: [String]) -> [String] {
        var out: [String] = []
        if let e {
            let arm = e["arm"] as? [String] ?? []
            let reach = (e["reach_cm"] as? NSNumber).map { "; reach ≈ \($0.intValue) cm" } ?? ""
            if !arm.isEmpty { out.append("- Arm: \(arm.count) motorized joints up to the tool (\(arm.joined(separator: ", ")))\(reach).") }
            if let g = e["gripper"] as? String {
                let oneJaw = e["one_jaw"] as? Bool ?? false, fingers = (e["fingers"] as? NSNumber)?.intValue ?? 1
                let kind = oneJaw ? "one moving jaw against a fixed one" : "\(fingers) moving fingers"
                let opens = (e["max_opening_cm"] as? NSNumber).map { ", opens up to ≈ \(String(format: "%.1f", $0.doubleValue)) cm" } ?? ""
                let turn = e["can_turn"] as? Bool == true ? " and turns to match the object" : ""
                out.append("- Gripper: \(kind) (\(g))\(opens); picks from above\(turn).")
            } else {
                out.append("- No gripper recognized: pick and place won't work.")
            }
        }
        if !cameras.isEmpty { out.append("- Cameras: " + cameras.joined(separator: ", ") + ".") }
        return out
    }

    /// La herramienta con que la IA guarda una lección (la corre el chat, no el robot).
    static let rememberTool: [String: Any] = [
        "name": "remember",
        "description": "Saves one short lesson about this robot, its table or its objects, for future conversations (e.g. 'Jenga blocks slip if gripped along the long side'). Only lasting facts, not one-off results.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "properties": ["note": ["type": "string"]],
            "required": ["note"],
            "additionalProperties": false,
        ] as [String: Any],
    ]
}
