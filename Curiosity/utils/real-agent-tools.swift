import Foundation

/// Las herramientas con las que la IA maneja el robot real (SO-101), su prompt y cómo se describe cada
/// acción. Solo datos y transformaciones: la ejecución está en use-live-robot.
enum RealAgentTools {
    static let joints = ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"]

    static let definitions: [[String: Any]] = [
        tool("get_state",
             "Reads where each joint of the real robot is, where it's heading and its allowed range. Use it before planning a move.",
             properties: [:], required: []),
        tool("move_joints",
             "Moves the real robot toward these targets, slowly (about 40° per second). The user has to approve each move before it happens. Returns the state on arrival.",
             properties: [
                "targets": [
                    "type": "array",
                    "description": "Targets. Degrees for the joints; the gripper goes from 0 to 100.",
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
        tool("look", "Takes a picture with each robot camera (the main one and any others) to see the table, the arm and the objects.",
             properties: [:], required: []),
        tool("go_home", "Slowly returns to the pose the robot was in when it was connected. Also requires approval.",
             properties: [:], required: []),
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "strict": true,
         "input_schema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false] as [String: Any]]
    }

    static let lookReferences: [String: Any] = tool(
        "look_references", "Shows the key-moment pictures from the demonstrations you studied, to compare with what you see.",
        properties: [:], required: [])

    static func systemPrompt(robotName: String, limits: [String: ClosedRange<Double>]) -> String {
        let ranges = joints.compactMap { j in
            limits[j].map { "- \(j): \(format($0.lowerBound, j)) to \(format($0.upperBound, j)) (full travel \(format($0.upperBound - $0.lowerBound, j)))" }
        }.joined(separator: "\n")
        return """
        You are the assistant in Curiosity and you control a REAL robotic arm, an SO-101 named \(robotName), \
        on a table. It has a camera looking at the scene. The user asks you for things in natural language and \
        you turn them into movements. If there's more than one camera (for example a top-down view), \
        "look" gives you one picture from each, with its name: combine them to locate things.

        Joints (degrees; the gripper from 0 to 100) and their allowed range. It comes from this robot's \
        calibration (the furthest each motor moved during calibration, with a 3° margin), so it's its real freedom; \
        each joint's 0° is the center of that travel:
        \(ranges)

        Rules, because this is a real robot:
        - The user approves each move before it happens: explain in one sentence what you're going to do and why.
        - Move in small steps (few joints and few degrees at a time) and look (look) to check.
        - Before the first move, read the state (get_state) and look at the scene.
        - The state includes where the gripper (gripper_cm) and the wrist (wrist_cm) are, in centimeters, in the \
        robot base frame (z up), computed with its 3D model. Each move returns the before, the after, \
        how much each joint changed, whether it got there and how far the gripper moved; also \
        the previous moves. Use this to learn which way each joint moves and to correct.
        - When you look, besides the cameras you get an image of the 3D model in the robot's current pose.
        - Never try to go outside the range: the state tells you how much room is left on each side (room_to_min, \
        room_to_max) and where in its travel it is (percent_of_range). If something seems odd or dangerous, \
        stop and ask.
        - You don't know in advance which way the gripper opens: try a small change and look.
        - Reply in the user's language, briefly and without unnecessary jargon.
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
        case "go_home": return "All joints to the starting pose."
        default: return nil
        }
    }

    static func title(for name: String) -> String {
        switch name {
        case "get_state": "Reading the state"
        case "move_joints": "Move the robot"
        case "look": "Looking through the camera"
        case "go_home": "Return to the starting pose"
        default: name
        }
    }

    static func format(_ v: Double, _ joint: String) -> String {
        joint == "gripper" ? "\(Int(v.rounded()))" : "\(Int(v.rounded()))°"
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
