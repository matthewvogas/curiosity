import Foundation

/// Las herramientas con las que la IA maneja el robot real (SO-101), su prompt y cómo se describe cada
/// acción. Solo datos y transformaciones: la ejecución está en use-live-robot.
enum RealAgentTools {
    static let joints = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

    static let definitions: [[String: Any]] = [
        tool("get_state",
             "Lee dónde está cada articulación del robot real, a dónde va y su rango permitido. Úsala antes de planear un movimiento.",
             properties: [:], required: []),
        tool("move_joints",
             "Mueve el robot real hacia estos objetivos, despacio (unos 40° por segundo). La persona tiene que aprobar cada movimiento antes de que ocurra. Devuelve el estado al llegar.",
             properties: [
                "targets": [
                    "type": "array",
                    "description": "Objetivos. Grados para las articulaciones; la pinza (gripper) va de 0 a 100.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "joint": ["type": "string", "enum": joints],
                            "value": ["type": "number"],
                        ],
                        "required": ["joint", "value"],
                        "additionalProperties": false,
                    ],
                ],
             ], required: ["targets"]),
        tool("look", "Toma una foto con la cámara del robot para ver la mesa, el brazo y los objetos.",
             properties: [:], required: []),
        tool("go_home", "Vuelve despacio a la pose en que estaba el robot al conectarlo. También requiere aprobación.",
             properties: [:], required: []),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "strict": true,
         "input_schema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false] as [String: Any]]
    }

    static func systemPrompt(robotName: String, limits: [String: ClosedRange<Double>]) -> String {
        let ranges = joints.compactMap { j in
            limits[j].map { "- \(j): \(format($0.lowerBound, j)) a \(format($0.upperBound, j))" }
        }.joined(separator: "\n")
        return """
        Eres el asistente de Curiosity y controlas un brazo robótico REAL, un SO-101 llamado \(robotName), \
        sobre una mesa. Tiene una cámara que mira la escena. La persona te pide cosas en lenguaje natural y \
        tú las conviertes en movimientos.

        Articulaciones (grados; la pinza de 0 a 100) y su rango permitido:
        \(ranges)

        Reglas, porque es un robot de verdad:
        - Cada movimiento lo aprueba la persona antes de que ocurra: explica en una frase qué vas a hacer y por qué.
        - Mueve en pasos chicos (pocas articulaciones y pocos grados a la vez) y mira (look) para comprobar.
        - Antes del primer movimiento, lee el estado (get_state) y mira la escena.
        - Nunca intentes salirte del rango. Si algo parece raro o peligroso, detente y pregunta.
        - No sabes de antemano en qué sentido abre la pinza: pruébalo con un cambio chico y mira.
        - Responde en el idioma de la persona, breve y sin tecnicismos innecesarios.
        """
    }

    /// Estado legible por la IA.
    static func describe(joints current: [String: Double], targets: [String: Double], limits: [String: ClosedRange<Double>]) -> [String: Any] {
        ["joints": joints.map { j -> [String: Any] in
            var out: [String: Any] = ["joint": j, "position": round1(current[j] ?? 0), "target": round1(targets[j] ?? 0),
                                      "unit": j == "gripper" ? "0-100" : "°"]
            if let l = limits[j] { out["limits"] = [round1(l.lowerBound), round1(l.upperBound)] }
            return out
        }]
    }

    /// Lo que se le muestra a la persona para aprobar: el comando exacto.
    static func approval(for name: String, input: [String: Any], current: [String: Double]) -> String? {
        switch name {
        case "move_joints":
            return (input["targets"] as? [[String: Any]] ?? []).compactMap { t -> String? in
                guard let j = t["joint"] as? String, let v = (t["value"] as? NSNumber)?.doubleValue else { return nil }
                return "\(j): \(format(current[j] ?? 0, j)) → \(format(v, j))"
            }.joined(separator: "\n")
        case "go_home": return "Todas las articulaciones a la pose del principio."
        default: return nil
        }
    }

    static func title(for name: String) -> String {
        switch name {
        case "get_state": "Leyendo el estado"
        case "move_joints": "Mover el robot"
        case "look": "Mirando con la cámara"
        case "go_home": "Volver a la pose del principio"
        default: name
        }
    }

    static func format(_ v: Double, _ joint: String) -> String {
        joint == "gripper" ? "\(Int(v.rounded()))" : "\(Int(v.rounded()))°"
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
