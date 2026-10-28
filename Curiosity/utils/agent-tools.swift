import Foundation

/// Las herramientas con las que la IA maneja el robot simulado, el prompt del sistema y el formato
/// del estado que se le devuelve. Solo datos y transformaciones: la ejecución está en use-chat.
enum AgentTools {
    // MARK: - Herramientas

    static let definitions: [[String: Any]] = [
        tool("get_state",
             "Reads the current state: each joint (position, target, limits, force) and the objects in the scene. Use it before planning a move.",
             properties: [:], required: []),
        tool("move_joints",
             "Sends targets to the joints and runs the simulation for a few seconds so the robot moves. Motors have limited force: if something blocks it, it won't reach the target. Returns the final state.",
             properties: [
                "targets": [
                    "type": "array",
                    "description": "Targets. Values in degrees for joints that rotate and in centimeters for joints that slide.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "joint": ["type": "string", "description": "Exact joint name."],
                            "value": ["type": "number", "description": "Target in degrees or centimeters."],
                        ],
                        "required": ["joint", "value"],
                        "additionalProperties": false,
                    ],
                ],
                "seconds": ["type": "number", "description": "How long to run the simulation afterwards, in seconds (0.2 to 5). Default 1.5."],
             ], required: ["targets", "seconds"]),
        tool("look",
             "Takes a picture of the scene to see where the robot and objects are. With no camera, it uses the main view; with the name of a camera mounted on the robot, the view from there.",
             properties: [
                "camera": ["type": "string", "description": "Name of a robot camera, or empty for the main view."],
             ], required: ["camera"]),
        tool("add_object",
             "Puts an object in the scene (it falls with gravity). Position in centimeters in the robot base frame (z up).",
             properties: [
                "shape": ["type": "string", "enum": ["box", "sphere", "cylinder"]],
                "size_cm": ["type": "array", "items": ["type": "number"],
                            "description": "box: [length, width, height] · sphere: [radius] · cylinder: [radius, height]"],
                "mass_g": ["type": "number"],
                "position_cm": ["type": "array", "items": ["type": "number"], "description": "[x, y, z]"],
                "color": ["type": "string", "description": "Hex color, for example #e4572e."],
             ], required: ["shape", "size_cm", "mass_g", "position_cm", "color"]),
        tool("remove_object", "Removes an object from the scene by its id.",
             properties: ["id": ["type": "integer"]], required: ["id"]),
        tool("reset", "Returns the robot to its starting pose, at rest. Doesn't move the objects.",
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
        let joints = model.actuatedJoints.map { j -> String in
            let range = (j.lower != nil && j.upper != nil)
                ? "\(Units.format(j.lower!, jointType: j.type)) to \(Units.format(j.upper!, jointType: j.type))"
                : "no limit"
            return "- \(j.name) (\(j.type == "prismatic" ? "slides" : "rotates"), \(range), max force \(String(format: "%.1f", j.fmax)))"
        }.joined(separator: "\n")
        let cameras = model.cameras.isEmpty ? "none" : model.cameras.joined(separator: ", ")
        return """
        You are the assistant in Curiosity, a robot simulator. You control a simulated robot with real \
        physics (gravity, collisions, friction, force-limited motors) through tools. The user asks you \
        for tasks in natural language; you turn them into movements.

        Robot: \(robotName) (model "\(model.name)"), \(model.links.count) parts, \(model.floating ? "free base (it can fall over)" : "fixed base").
        Motorized joints (the only ones you can command):
        \(joints)\(passive(model))
        Mounted cameras: \(cameras).

        How to work:
        - Before moving, look (look) and read the state (get_state) if you don't know where everything is.
        - Move in short steps and check the result; correct it if it didn't get there.
        - The frame is the robot base frame: z up, in centimeters. Joints are commanded in degrees \
        (or centimeters if they slide) and never outside their limits.
        - This is a simulation: there's no physical risk, but explain in one sentence what you're going to do.
        - Reply in the user's language, briefly and without unnecessary jargon.
        """
    }

    private static func passive(_ model: RobotModel) -> String {
        let rest = model.joints.filter { !$0.actuated }
        guard !rest.isEmpty else { return "" }
        let list = rest.map { j in j.mimic.map { m in "\(j.name) (follows \(m))" } ?? "\(j.name) (no motor)" }
        return "\nMove on their own: " + list.joined(separator: ", ") + "."
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
        case "get_state": return "Reading the state"
        case "move_joints":
            let targets = (input["targets"] as? [[String: Any]] ?? [])
                .map { "\($0["joint"] ?? "") → \(round1(($0["value"] as? NSNumber)?.doubleValue ?? 0))" }
            return "Moving " + (targets.isEmpty ? "the robot" : targets.joined(separator: ", "))
        case "look":
            let cam = input["camera"] as? String ?? ""
            return cam.isEmpty ? "Looking at the scene" : "Looking from \"\(cam)\""
        case "add_object": return "Adding an object (\(input["shape"] as? String ?? ""))"
        case "remove_object": return "Removing object \(input["id"] ?? "")"
        case "reset": return "Returning to the starting pose"
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
