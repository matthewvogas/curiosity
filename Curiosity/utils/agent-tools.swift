import Foundation

/// Las herramientas con las que la IA maneja el robot simulado, el prompt del sistema y el formato
/// del estado que se le devuelve. Solo datos y transformaciones: la ejecución está en use-chat.
enum AgentTools {
    // MARK: - Herramientas

    static let definitions: [[String: Any]] = [
        tool("get_state",
             "Reads what the robot feels: each joint (position, target, limits, force). It does NOT say where objects are: for that, look through a camera.",
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
             "Takes a picture through one of the robot's cameras. It comes with a pixel grid (labels every 64 px) and its size, so you can point at things for pick and place.",
             properties: [
                "camera": ["type": "string", "description": "Camera name (for example the fixed one over the table)."],
             ], required: ["camera"]),
        tool("pick",
             "Picks up an object on its own, in real time. You mark in a camera picture where each finger goes: two points on opposite sides of the object, across its narrow side, on its top edge. The arm works out the whole move (it turns the gripper to match, opens just enough, goes down, closes and lifts). Returns whether the gripper is holding something (felt by the gripper) and a new picture.",
             properties: [
                "camera": ["type": "string", "description": "The camera of the picture you're pointing in."],
                "finger_a_x": ["type": "number", "description": "Pixel x where one finger should touch the object (on one side of it)."],
                "finger_a_y": ["type": "number", "description": "Pixel y of that point."],
                "finger_b_x": ["type": "number", "description": "Pixel x where the other finger should touch (the opposite side, across the object's narrow side)."],
                "finger_b_y": ["type": "number", "description": "Pixel y of that point."],
                "height_cm": ["type": "number", "description": "Your estimate of the object's height, in cm (e.g. 2.5 for a small cube)."],
             ], required: ["camera", "finger_a_x", "finger_a_y", "finger_b_x", "finger_b_y", "height_cm"]),
        tool("place",
             "Puts down what the gripper is holding, on its own: you point at the spot in a camera picture; the arm goes there, lowers it, opens and goes back up. Returns a new picture.",
             properties: [
                "camera": ["type": "string", "description": "The camera of the picture you're pointing in."],
                "x": ["type": "number", "description": "Pixel x of where it should go."],
                "y": ["type": "number", "description": "Pixel y of where it should go."],
                "height_cm": ["type": "number", "description": "Height of the object being held, in cm."],
                "surface_cm": ["type": "number", "description": "Height of the surface it goes on: 0 for the table, or the height of the object it goes on top of."],
             ], required: ["camera", "x", "y", "height_cm", "surface_cm"]),
        tool("gripper",
             "Opens or closes the gripper and says whether it's holding something.",
             properties: ["open": ["type": "boolean"]], required: ["open"]),
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
        tool("create_object",
             "Creates a real-world object from a description (a wheel, a desk, a kitchen knife, a mug…) with its real size and weight, built from simple parts, and drops it on a free spot of the table. Use it instead of add_object for anything that isn't a plain box, ball or cylinder.",
             properties: [
                "description": ["type": "string", "description": "What the object is, with any detail that matters (size, material, color)."],
             ], required: ["description"]),
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
        Cameras: \(cameras).

        This works like a real robot: you don't know where objects are except by looking through a camera. \
        You're the planner and the eyes; the arm has its own controller that does the movement in real time.

        How to work:
        - Look through the fixed camera over the table (look) to find things. Point in pixels, using the grid.
        - To move objects use pick and place: you say what (pixels) and the arm works out how. For pick, mark \
        where each finger goes (opposite sides across the object's narrow side), so the gripper turns to match. Each one \
        returns a new picture: check it, and if it failed (missed, nothing in the gripper), point again more \
        carefully and retry.
        - Use move_joints only for things pick/place can't do (gestures, small adjustments).
        - To add things to the scene, use create_object with a plain description; it builds them at real scale.
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
    static func describe(state: SimulationState, model: RobotModel) -> [String: Any] {
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
        // Como un robot real: solo lo que siente (sus articulaciones), no dónde están los objetos.
        return ["time_s": round1(state.time), "joints": joints]
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
        case "create_object": return "Creating \(input["description"] as? String ?? "an object")"
        case "remove_object": return "Removing object \(input["id"] ?? "")"
        case "reset": return "Returning to the starting pose"
        case "pick": return "Picking up what's between \(pixel(input, "finger_a")) and \(pixel(input, "finger_b"))"
        case "place": return "Putting it down at (\(Int((input["x"] as? NSNumber)?.doubleValue ?? 0)), \(Int((input["y"] as? NSNumber)?.doubleValue ?? 0)))"
        case "gripper": return (input["open"] as? Bool ?? true) ? "Opening the gripper" : "Closing the gripper"
        default: return name
        }
    }

    /// «(x, y)» de un punto de la entrada de una herramienta (p. ej. finger_a → finger_a_x, finger_a_y).
    static func pixel(_ input: [String: Any], _ key: String) -> String {
        let v = { (k: String) in Int((input[k] as? NSNumber)?.doubleValue ?? 0) }
        return "(\(v(key + "_x")), \(v(key + "_y")))"
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
