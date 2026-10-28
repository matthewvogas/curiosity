import Foundation

/// Las herramientas con las que la IA maneja el robot simulado, el prompt del sistema y el formato
/// del estado que se le devuelve. Solo datos y transformaciones: la ejecución está en use-chat.
enum AgentTools {
    // MARK: - Herramientas

    static let definitions: [[String: Any]] = [
        tool("get_state",
             "Lee el estado actual: cada articulación (posición, objetivo, límites, fuerza) y los objetos de la escena. Úsala antes de planear un movimiento.",
             properties: [:], required: []),
        tool("move_joints",
             "Manda objetivos a las articulaciones y deja correr la simulación unos segundos para que el robot se mueva. Los motores tienen fuerza limitada: si algo lo bloquea, no llegará al objetivo. Devuelve el estado final.",
             properties: [
                "targets": [
                    "type": "array",
                    "description": "Objetivos. Valores en grados para articulaciones que giran y en centímetros para las que se deslizan.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "joint": ["type": "string", "description": "Nombre exacto de la articulación."],
                            "value": ["type": "number", "description": "Objetivo en grados o centímetros."],
                        ],
                        "required": ["joint", "value"],
                        "additionalProperties": false,
                    ],
                ],
                "seconds": ["type": "number", "description": "Cuánto dejar correr la simulación después (0.2 a 5). Por defecto 1.5."],
             ], required: ["targets", "seconds"]),
        tool("look",
             "Toma una foto de la escena para ver dónde están el robot y los objetos. Sin cámara, usa la vista principal; con el nombre de una cámara montada en el robot, la vista desde ahí.",
             properties: [
                "camera": ["type": "string", "description": "Nombre de una cámara del robot, o vacío para la vista principal."],
             ], required: ["camera"]),
        tool("add_object",
             "Pone un objeto en la escena (cae con gravedad). Posición en centímetros en el marco de la base del robot (z hacia arriba).",
             properties: [
                "shape": ["type": "string", "enum": ["box", "sphere", "cylinder"]],
                "size_cm": ["type": "array", "items": ["type": "number"],
                            "description": "box: [largo, ancho, alto] · sphere: [radio] · cylinder: [radio, alto]"],
                "mass_g": ["type": "number"],
                "position_cm": ["type": "array", "items": ["type": "number"], "description": "[x, y, z]"],
                "color": ["type": "string", "description": "Color en hexadecimal, por ejemplo #e4572e."],
             ], required: ["shape", "size_cm", "mass_g", "position_cm", "color"]),
        tool("remove_object", "Quita un objeto de la escena por su id.",
             properties: ["id": ["type": "integer"]], required: ["id"]),
        tool("reset", "Vuelve el robot a su pose inicial, quieto. No mueve los objetos.",
             properties: [:], required: []),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    // MARK: - Prompt del sistema

    static func systemPrompt(model: RobotModel, robotName: String) -> String {
        let joints = model.joints.map { j -> String in
            let range = (j.lower != nil && j.upper != nil)
                ? "\(Units.format(j.lower!, jointType: j.type)) a \(Units.format(j.upper!, jointType: j.type))"
                : "sin límite"
            return "- \(j.name) (\(j.type == "prismatic" ? "desliza" : "gira"), \(range), fuerza máx. \(String(format: "%.1f", j.fmax)))"
        }.joined(separator: "\n")
        let cameras = model.cameras.isEmpty ? "ninguna" : model.cameras.joined(separator: ", ")
        return """
        Eres el asistente de Curiosity, un simulador de robots. Controlas un robot simulado con física \
        real (gravedad, choques, fricción, motores con fuerza limitada) a través de herramientas. La \
        persona te pide tareas en lenguaje natural; tú las conviertes en movimientos.

        Robot: \(robotName) (modelo «\(model.name)»), \(model.links.count) piezas.
        Articulaciones:
        \(joints)
        Cámaras montadas: \(cameras).

        Cómo trabajar:
        - Antes de mover, mira (look) y lee el estado (get_state) si no sabes dónde está todo.
        - Mueve en pasos cortos y comprueba el resultado; corrige si no llegó.
        - El marco es el de la base del robot: z hacia arriba, en centímetros. Las articulaciones se \
        mandan en grados (o centímetros si se deslizan) y nunca fuera de sus límites.
        - Esto es una simulación: no hay riesgo físico, pero explica en una frase qué vas a hacer.
        - Responde en el idioma de la persona, breve y sin tecnicismos innecesarios.
        """
    }

    // MARK: - Estado para la IA

    /// Estado legible por la IA, en grados y centímetros.
    static func describe(state: SimulationState, model: RobotModel, objects: [SceneObject]) -> [String: Any] {
        let info = Dictionary(uniqueKeysWithValues: model.joints.map { ($0.name, $0) })
        let joints = state.joints.map { s -> [String: Any] in
            let type = info[s.name]?.type ?? "revolute"
            var out: [String: Any] = [
                "joint": s.name,
                "position": round1(Units.toDisplay(s.q, jointType: type)),
                "target": round1(Units.toDisplay(s.target, jointType: type)),
                "unit": Units.symbol(jointType: type),
                "force": round1(s.force),
            ]
            if let lo = info[s.name]?.lower, let hi = info[s.name]?.upper {
                out["limits"] = [round1(Units.toDisplay(lo, jointType: type)), round1(Units.toDisplay(hi, jointType: type))]
            }
            return out
        }
        let objs = objects.map { o -> [String: Any] in
            ["id": o.id, "shape": o.shape, "color": o.color,
             "position_cm": Units.centimeters(state.objectPositions[o.id] ?? o.pos)]
        }
        return ["time_s": round1(state.time), "joints": joints, "objects": objs, "contacts": state.contacts]
    }

    /// Una frase corta para mostrar en el chat lo que hace cada herramienta.
    static func title(for name: String, input: [String: Any]) -> String {
        switch name {
        case "get_state": return "Leyendo el estado"
        case "move_joints":
            let targets = (input["targets"] as? [[String: Any]] ?? [])
                .map { "\($0["joint"] ?? "") → \(round1(($0["value"] as? NSNumber)?.doubleValue ?? 0))" }
            return "Moviendo " + (targets.isEmpty ? "el robot" : targets.joined(separator: ", "))
        case "look":
            let cam = input["camera"] as? String ?? ""
            return cam.isEmpty ? "Mirando la escena" : "Mirando desde «\(cam)»"
        case "add_object": return "Poniendo un objeto (\(input["shape"] as? String ?? ""))"
        case "remove_object": return "Quitando el objeto \(input["id"] ?? "")"
        case "reset": return "Volviendo a la pose inicial"
        default: return name
        }
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
