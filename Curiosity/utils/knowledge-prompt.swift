import Foundation

/// Estudiar demostraciones (preparación «en contexto», como en el paper de GPT-6-Astra): qué se le manda a la
/// IA, la herramienta con la que escribe el paquete y cómo se le presenta después en vivo. Solo datos.
enum KnowledgePrompt {
    // MARK: - Estudio

    static let studySystem = """
    You are the assistant in Curiosity. You're going to study demonstrations recorded with a robot (the dataset says \
    which) to write a knowledge package. Later, another session of yours \
    will use it to do the task on a real robot, live, without training any network: it will read your guide, go to \
    the poses you save and replay the segments you choose, adapting them to what it sees.

    Each joint's unit is given with the data: degrees (0° is the center of the calibrated travel) or the motor's \
    0–100 / −100–100 scale. Times are \
    seconds from the start of each demonstration.

    Write the package with the write_package tool:
    - summary: what the task does and the overall strategy, in 2-4 sentences.
    - stages: the stages in order (approach, grasp, lift, carry, release, return…), each with its \
    goal and a concrete, visible check that it was achieved.
    - poses: key moments to go to directly (for example "above the object", "grasp", "above the target"): \
    pick the exact demonstration and second from the trajectories I give you.
    - segments: segments to replay as-is (for example from the approach to the grasp): demonstration, \
    from and to in seconds. Prefer segments from the cleanest demonstration.
    - tips: what you notice matters (speed, order, where the gripper comes from, what fails easily).
    Write in English.
    """

    static let writePackage: [String: Any] = [
        "name": "write_package",
        "description": "Saves the studied knowledge package.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "stages", "poses", "segments", "tips"],
            "properties": [
                "title": ["type": "string", "description": "Short name of the task."],
                "summary": ["type": "string"],
                "stages": ["type": "array", "items": object(["name": "string", "goal": "string", "check": "string"])],
                "poses": ["type": "array", "items": object(["name": "string", "episode": "integer", "at_s": "number", "note": "string"])],
                "segments": ["type": "array", "items": object(["name": "string", "episode": "integer", "from_s": "number", "to_s": "number", "note": "string"])],
                "tips": ["type": "array", "items": ["type": "string"]],
            ] as [String: Any],
        ] as [String: Any],
    ]

    private static func object(_ fields: [String: String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": Array(fields.keys),
         "properties": fields.mapValues { ["type": $0] }]
    }

    /// El mensaje con todo lo estudiable: datos del dataset, trayectorias (2 por segundo) y las fotos clave.
    static func studyMessage(_ m: StudyMaterial) -> [[String: Any]] {
        var content: [[String: Any]] = []
        let tasks = (m.info["tasks"] as? [String] ?? []).joined(separator: " · ")
        content.append(["type": "text", "text": """
        Dataset \(m.repoID): \(m.info["total_episodes"] ?? "?") demonstrations at \(m.info["fps"] ?? "?") fps, robot \
        \(m.info["robot_type"] ?? "?"), cameras \((m.info["cameras"] as? [String] ?? []).joined(separator: ", ")). \
        Task: \(tasks). Trajectory columns: t (s), \(m.joints.map { j in "\(j) (\((m.info["joint_units"] as? [String: String])?[j] ?? "?"))" }.joined(separator: ", ")).
        """])
        for e in m.episodes {
            let rows = e.trajectory.enumerated().filter { $0.offset % 5 == 0 || $0.offset == e.trajectory.count - 1 }.map(\.element)
            let table = rows.map { r in r.map { String(format: "%.1f", $0) }.joined(separator: " ") }.joined(separator: "\n")
            let events = e.events.map { "\($0["t"] ?? "") s: gripper \($0["gripper"] ?? "")" }.joined(separator: "; ")
            content.append(["type": "text", "text": """
            Demonstration \(e.index) (\(String(format: "%.1f", e.duration)) s). Gripper: \(events.isEmpty ? "no clear changes" : events).
            t shoulder_pan shoulder_lift elbow_flex wrist_flex wrist_roll gripper
            \(table)
            """])
        }
        for p in m.pictures {
            content.append(["type": "text", "text": "Demonstration \(p.episode), \(p.label):"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": p.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": "Study everything and write the package with write_package."])
        return content
    }

    /// Arma el paquete con lo que escribió la IA; las poses salen de las trayectorias reales (no de números copiados).
    static func package(from input: [String: Any], material m: StudyMaterial) -> KnowledgePackage {
        let byEpisode = Dictionary(uniqueKeysWithValues: m.episodes.map { ($0.index, $0.trajectory) })
        func strings(_ key: String, _ item: [String: Any]) -> String { item[key] as? String ?? "" }
        func number(_ key: String, _ item: [String: Any]) -> Double { (item[key] as? NSNumber)?.doubleValue ?? 0 }
        let poses = (input["poses"] as? [[String: Any]] ?? []).compactMap { p -> KnowledgePackage.Pose? in
            let e = Int(number("episode", p)), at = number("at_s", p)
            guard let traj = byEpisode[e], let row = traj.min(by: { abs($0[0] - at) < abs($1[0] - at) }),
                  row.count == m.joints.count + 1 else { return nil }
            return .init(name: strings("name", p), joints: Dictionary(uniqueKeysWithValues: zip(m.joints, row.dropFirst())),
                         note: strings("note", p))
        }
        let segments = (input["segments"] as? [[String: Any]] ?? []).compactMap { s -> KnowledgePackage.Segment? in
            let e = Int(number("episode", s))
            guard byEpisode[e] != nil else { return nil }
            return .init(name: strings("name", s), episode: e, from: number("from_s", s), to: number("to_s", s), note: strings("note", s))
        }
        return KnowledgePackage(
            source: m.repoID, title: strings("title", input), summary: strings("summary", input),
            stages: (input["stages"] as? [[String: Any]] ?? []).map { .init(name: strings("name", $0), goal: strings("goal", $0), check: strings("check", $0)) },
            poses: poses, segments: segments, tips: input["tips"] as? [String] ?? [],
            trajectories: Dictionary(uniqueKeysWithValues: m.episodes.map { (String($0.index), $0.trajectory) }), joints: m.joints,
            pictures: m.pictures.prefix(4).map { .init(label: "Demonstration \($0.episode), \($0.label)", jpeg: $0.jpeg) })
    }

    // MARK: - En vivo

    /// Lo que se agrega al prompt del robot en vivo cuando hay un paquete activo.
    static func liveSection(_ k: KnowledgePackage) -> String {
        let stages = k.stages.enumerated().map { "\($0.offset + 1). \($0.element.name): \($0.element.goal) — achieved if: \($0.element.check)" }
        let poses = k.poses.map { p in
            "- \"\(p.name)\": " + k.jointOrder.filter { p.joints[$0] != nil }.map { "\($0) \(RealAgentTools.format(p.joints[$0] ?? 0, $0))" }.joined(separator: ", ") + (p.note.isEmpty ? "" : " (\(p.note))")
        }
        let segments = k.segments.map { "- \"\($0.name)\": demonstration \($0.episode), from \($0.from) to \($0.to) s\($0.note.isEmpty ? "" : " (\($0.note))")" }
        return """

        You studied demonstrations of this task (\(k.source)). Your knowledge package:
        \(k.summary)

        Stages:
        \(stages.joined(separator: "\n"))

        Saved poses (go_to_pose):
        \(poses.joined(separator: "\n"))

        Segments to replay (play_segment):
        \(segments.joined(separator: "\n"))

        Tips: \(k.tips.joined(separator: " · "))

        How to use it: follow the stages; for each one, recall the matching pose or segment, adapt it to \
        what you see (offsets of a few degrees if the object is somewhere other than in the demonstrations), \
        run it and verify that stage's check with the camera before moving on. The demonstrations may \
        come from another identical robot with a different calibration: treat them as a reference, not exact truth.
        """
    }

    /// Se arma en cada uso: las articulaciones son las del robot conectado.
    static var liveTools: [[String: Any]] { [
        [
            "name": "go_to_pose", "strict": true,
            "description": "Takes the robot to a saved pose from the knowledge package, with optional adjustments in degrees. Requires approval.",
            "input_schema": ["type": "object", "additionalProperties": false, "required": ["name", "offsets"],
                             "properties": ["name": ["type": "string"], "offsets": offsets]] as [String: Any],
        ],
        [
            "name": "play_segment", "strict": true,
            "description": "Replays on the robot a segment of a demonstration from the package (it first moves slowly to its start). speed from 0.25 to 1 (default 0.5). Requires approval.",
            "input_schema": ["type": "object", "additionalProperties": false, "required": ["name", "speed", "offsets"],
                             "properties": ["name": ["type": "string"], "speed": ["type": "number"], "offsets": offsets]] as [String: Any],
        ],
    ] }

    private static var offsets: [String: Any] { [
        "type": "array",
        "description": "Adjustments to add to each point, in each joint's unit. Empty if not needed.",
        "items": ["type": "object", "additionalProperties": false, "required": ["joint", "delta"],
                  "properties": ["joint": ["type": "string", "enum": RealAgentTools.joints], "delta": ["type": "number"]]],
    ] }
}
