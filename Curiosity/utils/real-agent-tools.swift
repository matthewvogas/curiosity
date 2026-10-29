import Foundation

/// Las herramientas con las que la IA maneja el robot real, su prompt y cómo se describe cada acción. Solo datos y
/// transformaciones: la ejecución está en use-live-robot.
enum RealAgentTools {
    /// Las articulaciones del robot conectado, en orden, su unidad («deg», «0-100», «±100») y su tipo en LeRobot.
    /// Las pone la sesión en vivo con lo que dice LeRobot; nada de aquí supone un robot en particular.
    static var joints: [String] = []
    static var units: [String: String] = [:]
    static var robotType = ""

    static var definitions: [[String: Any]] { [
        tool("get_state",
             "Reads where each joint of the real robot is, where it's heading and its allowed range. Use it before planning a move.",
             properties: [:], required: []),
        tool("move_joints",
             "Moves the real robot toward these targets, slowly (about 40° per second for joints in degrees). The user has to approve each move before it happens. Returns the state on arrival.",
             properties: [
                "targets": [
                    "type": "array",
                    "description": "Targets, each in its joint's unit (see get_state).",
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
    ] }

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "strict": true,
         "input_schema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false] as [String: Any]]
    }

    /// Mandarle una orden en palabras al modelo de órdenes (SmolVLA, π0…), que la hace solo a 30 Hz.
    static let runSkill: [String: Any] = tool(
        "run_skill",
        "Gives a short instruction to the robot's own action model, which carries it out on its own in real time (30 times per second) and is much faster than move_joints. Use it for whole sub-tasks. The user approves it first. When it ends you get how it ended, the state and a picture from each camera.",
        properties: [
            "instruction": ["type": "string", "description": "One short, concrete action in English, like the ones the model was trained on. E.g. \"pick up the red cube and place it in the box\"."],
            "seconds": ["type": "number", "description": "Maximum time it may take, 3 to 60 seconds."],
        ], required: ["instruction", "seconds"])

    /// Lo que se agrega al prompt cuando hay un modelo de órdenes cargado.
    static func skillSection(_ model: SkillModel) -> String {
        """


        You also have an action model on the robot (\(model.type), \(URL(fileURLWithPath: model.path).lastPathComponent)). \
        Work as a planner: split the user's request into short sub-tasks and give each one to run_skill; \
        it does the movement much faster than you can with move_joints. After each run_skill, look at the \
        pictures it returns and decide the next step (retry, correct with small move_joints, or move on). \
        Use move_joints only for small fixes or when the model can't do something.
        """
    }

    static func clampSkillSeconds(_ input: [String: Any]) -> Double {
        min(60, max(3, (input["seconds"] as? NSNumber)?.doubleValue ?? 15))
    }

    static let lookReferences: [String: Any] = tool(
        "look_references", "Shows the key-moment pictures from the demonstrations you studied, to compare with what you see.",
        properties: [:], required: [])

    /// Las habilidades del brazo: la IA señala en una foto y el brazo hace el movimiento entero solo.
    static let armTools: [[String: Any]] = [
        tool("pick",
             "Picks up an object in ONE continuous move. In a picture from a calibrated camera you mark where each finger goes: two points on opposite sides of the object, across its narrow side, on its top edge. The arm works out the whole motion with its own kinematics (turns the gripper to match, opens just enough, goes down, closes, lifts) and the user approves it once. Returns whether the gripper is holding something (felt by the gripper) and new pictures.",
             properties: [
                "camera": ["type": "string", "description": "Name of the calibrated camera whose picture you're pointing in."],
                "finger_a_x": ["type": "number", "description": "Pixel x where one finger should touch the object (on one side of it)."],
                "finger_a_y": ["type": "number", "description": "Pixel y of that point."],
                "finger_b_x": ["type": "number", "description": "Pixel x where the other finger should touch (the opposite side, across the object's narrow side)."],
                "finger_b_y": ["type": "number", "description": "Pixel y of that point."],
                "height_cm": ["type": "number", "description": "Your estimate of the object's height, in cm."],
             ], required: ["camera", "finger_a_x", "finger_a_y", "finger_b_x", "finger_b_y", "height_cm"]),
        tool("place",
             "Puts down what the gripper holds, in ONE continuous move: you point at the spot in a calibrated camera's picture. Returns new pictures.",
             properties: [
                "camera": ["type": "string", "description": "Name of the calibrated camera whose picture you're pointing in."],
                "x": ["type": "number", "description": "Pixel x of where it should go."],
                "y": ["type": "number", "description": "Pixel y of where it should go."],
                "height_cm": ["type": "number", "description": "Height of the object being held, in cm."],
                "surface_cm": ["type": "number", "description": "Height of the surface it goes on: 0 for the table, or the height of the object it goes on top of."],
             ], required: ["camera", "x", "y", "height_cm", "surface_cm"]),
        tool("gripper", "Opens or closes the gripper and says whether it's holding something.",
             properties: ["open": ["type": "boolean"]], required: ["open"]),
    ]

    static func systemPrompt(robotName: String, limits: [String: ClosedRange<Double>], calibratedCameras: [String]) -> String {
        let ranges = joints.compactMap { j in
            limits[j].map { "- \(j): \(format($0.lowerBound, j)) to \(format($0.upperBound, j))" }
        }.joined(separator: "\n")
        let cameras = calibratedCameras.isEmpty
            ? "None of the cameras is calibrated yet, so pick and place can't locate things. Tell the user to calibrate the camera in the Arm tab (about a minute) before anything else."
            : "Calibrated cameras (you can point in their pictures): \(calibratedCameras.joined(separator: ", "))."
        return """
        You are the assistant in Curiosity and you control a REAL robot (LeRobot type \(robotType)) named \(robotName), \
        on a table, seen by one or more cameras.

        How this works: you are the eyes and the planner; the arm has its own controller. You look, decide WHAT \
        to do and point at it in a picture (pixels, using the grid on the picture). pick and place then do the \
        whole movement on their own in one go, with the robot's kinematics and the limits of its calibration. \
        The user approves each action once.
        \(cameras)

        The robot's joints and their range, from its calibration (° is degrees; other joints use that motor's 0–100 or \
        −100–100 scale; a gripper at 0 is closed):
        \(ranges)

        Rules:
        - Start by looking (look). Find the objects in the calibrated camera's picture and point at them.
        - Split the request into actions (pick this, place it there) and use pick/place for each. After each \
        one, check the pictures it returns; if it missed or isn't holding anything, point more carefully and retry.
        - Don't move joint by joint to reach things: that's what pick/place are for. Use move_joints only for \
        small adjustments or gestures, never to approach objects.
        - Explain in one short sentence what you're about to do. Reply in the user's language, briefly.
        """
    }

    /// Estado legible por la IA.
    static func describe(joints current: [String: Double], targets: [String: Double], limits: [String: ClosedRange<Double>]) -> [String: Any] {
        ["joints": joints.map { j -> [String: Any] in
            var out: [String: Any] = ["joint": j, "position": round1(current[j] ?? 0), "target": round1(targets[j] ?? 0),
                                      "unit": units[j] == "deg" ? "°" : units[j] ?? ""]
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
        case "run_skill":
            return "The action model moves the robot on its own for up to \(Int(clampSkillSeconds(input))) s:\n«\(input["instruction"] as? String ?? "")»"
        default: return nil
        }
    }

    static func title(for name: String) -> String {
        switch name {
        case "get_state": "Reading the state"
        case "move_joints": "Move the robot"
        case "look": "Looking through the camera"
        case "go_home": "Return to the starting pose"
        case "run_skill": "Action model"
        default: name
        }
    }

    static func format(_ v: Double, _ joint: String) -> String { JointUnits.format(v, units[joint]) }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
