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
        tool("look", "Toma una foto con cada cámara del robot (la principal y las demás, si hay) para ver la mesa, el brazo y los objetos.",
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
            limits[j].map { "- \(j): de \(format($0.lowerBound, j)) a \(format($0.upperBound, j)) (recorrido total \(format($0.upperBound - $0.lowerBound, j)))" }
        }.joined(separator: "\n")
        return """
        Eres el asistente de Curiosity y controlas un brazo robótico REAL, un SO-101 llamado \(robotName), \
        sobre una mesa. Tiene una cámara que mira la escena. La persona te pide cosas en lenguaje natural y \
        tú las conviertes en movimientos. Si hay más de una cámara (por ejemplo una vista desde arriba), \
        «look» te da una foto de cada una con su nombre: combínalas para ubicar las cosas.

        Articulaciones (grados; la pinza de 0 a 100) y su rango permitido. Sale de la calibración de este \
        robot (lo máximo que se movió cada motor al calibrarlo, con 3° de margen), así que es su libertad real; \
        el 0° de cada una es el centro de ese recorrido:
        \(ranges)

        Reglas, porque es un robot de verdad:
        - Cada movimiento lo aprueba la persona antes de que ocurra: explica en una frase qué vas a hacer y por qué.
        - Mueve en pasos chicos (pocas articulaciones y pocos grados a la vez) y mira (look) para comprobar.
        - Antes del primer movimiento, lee el estado (get_state) y mira la escena.
        - El estado trae dónde está la pinza (gripper_cm) y la muñeca (wrist_cm) en centímetros, en el marco \
        de la base del robot (z hacia arriba), calculado con su modelo 3D. Cada movimiento te devuelve el \
        antes, el después, cuánto cambió cada articulación, si llegó y cuánto se desplazó la pinza; también \
        los movimientos anteriores. Úsalo para aprender en qué sentido mueve cada articulación y corregir.
        - Al mirar, además de las cámaras recibes una imagen del modelo 3D en la pose actual del robot.
        - Nunca intentes salirte del rango: el estado te dice cuánto le queda hacia cada lado (room_to_min, \
        room_to_max) y en qué parte del recorrido está (percent_of_range). Si algo parece raro o peligroso, \
        detente y pregunta.
        - No sabes de antemano en qué sentido abre la pinza: pruébalo con un cambio chico y mira.
        - Responde en el idioma de la persona, breve y sin tecnicismos innecesarios.
        """
    }

    /// Estado legible por la IA.
    static func describe(joints current: [String: Double], targets: [String: Double], limits: [String: ClosedRange<Double>]) -> [String: Any] {
        ["joints": joints.map { j -> [String: Any] in
            var out: [String: Any] = ["joint": j, "position": round1(current[j] ?? 0), "target": round1(targets[j] ?? 0),
                                      "unit": j == "gripper" ? "0-100" : "°"]
            if let l = limits[j] {
                let q = current[j] ?? 0, span = l.upperBound - l.lowerBound
                out["min"] = round1(l.lowerBound)
                out["max"] = round1(l.upperBound)
                // Cuánta libertad le queda hacia cada lado y en qué parte de su recorrido está (0 % = mínimo).
                out["room_to_min"] = round1(q - l.lowerBound)
                out["room_to_max"] = round1(l.upperBound - q)
                out["percent_of_range"] = span > 0 ? Int(((q - l.lowerBound) / span * 100).rounded()) : 0
            }
            return out
        }]
    }

    /// Un movimiento resumido: lo pedido, dónde estaba, dónde quedó, cuánto cambió cada articulación,
    /// si llegó, y cuánto se desplazó la pinza en el espacio.
    static func move(asked: [String: Double], start: [String: Double], end: [String: Double], before: Any?, after: Any?) -> [String: Any] {
        var out: [String: Any] = [
            "asked": asked.mapValues(round1),
            "before": start.filter { asked[$0.key] != nil }.mapValues(round1),
            "after": end.filter { asked[$0.key] != nil }.mapValues(round1),
            "change": asked.keys.reduce(into: [String: Double]()) { $0[$1] = round1((end[$1] ?? 0) - (start[$1] ?? 0)) },
            "reached": asked.keys.reduce(into: [String: Bool]()) { $0[$1] = abs((end[$1] ?? 0) - asked[$1]!) < 3 },
        ]
        if let b = before as? [Double], let a = after as? [Double], b.count == 3, a.count == 3 {
            out["gripper_before_cm"] = b
            out["gripper_after_cm"] = a
            out["gripper_moved_cm"] = zip(a, b).map { round1($0 - $1) }
        }
        return out
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
