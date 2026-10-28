import Foundation

/// Estudiar demostraciones (preparación «en contexto», como en el paper de GPT-6-Astra): qué se le manda a la
/// IA, la herramienta con la que escribe el paquete y cómo se le presenta después en vivo. Solo datos.
enum KnowledgePrompt {
    // MARK: - Estudio

    static let studySystem = """
    Eres el asistente de Curiosity. Vas a estudiar demostraciones grabadas con un brazo SO-101 (o SO-100, \
    que tiene las mismas articulaciones) para escribir un paquete de conocimiento. Después, otra sesión tuya \
    lo usará para hacer la tarea en un robot real, en vivo, sin entrenar ninguna red: leerá tu guía, irá a \
    las poses que guardes y reproducirá los tramos que elijas, adaptándolos a lo que vea.

    Articulaciones en grados (0° es el centro del recorrido calibrado); gripper de 0 a 100. Los tiempos son \
    segundos desde el inicio de cada demostración.

    Escribe el paquete con la herramienta write_package:
    - summary: qué hace la tarea y la estrategia general, en 2-4 frases.
    - stages: las etapas en orden (acercarse, agarrar, levantar, llevar, soltar, volver…), cada una con su \
    meta y una prueba concreta y visible de que se logró.
    - poses: momentos clave para ir directo (por ejemplo «sobre el objeto», «agarre», «sobre el destino»): \
    elige demostración y segundo exactos de las trayectorias que te doy.
    - segments: tramos para reproducir tal cual (por ejemplo del acercamiento al agarre): demostración, \
    desde y hasta en segundos. Prefiere tramos de la demostración más limpia.
    - tips: lo que notes que importa (velocidad, orden, de dónde viene la pinza, qué falla fácil).
    Responde en español.
    """

    static let writePackage: [String: Any] = [
        "name": "write_package",
        "description": "Guarda el paquete de conocimiento estudiado.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "summary", "stages", "poses", "segments", "tips"],
            "properties": [
                "title": ["type": "string", "description": "Nombre corto de la tarea."],
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
        Dataset \(m.repoID): \(m.info["total_episodes"] ?? "?") demostraciones a \(m.info["fps"] ?? "?") fps, robot \
        \(m.info["robot_type"] ?? "?"), cámaras \((m.info["cameras"] as? [String] ?? []).joined(separator: ", ")). \
        Tarea: \(tasks). Unidades: \(m.info["units"] ?? "grados").
        """])
        for e in m.episodes {
            let rows = e.trajectory.enumerated().filter { $0.offset % 5 == 0 || $0.offset == e.trajectory.count - 1 }.map(\.element)
            let table = rows.map { r in r.map { String(format: "%.1f", $0) }.joined(separator: " ") }.joined(separator: "\n")
            let events = e.events.map { "\($0["t"] ?? "") s: pinza \($0["gripper"] ?? "")" }.joined(separator: "; ")
            content.append(["type": "text", "text": """
            Demostración \(e.index) (\(String(format: "%.1f", e.duration)) s). Pinza: \(events.isEmpty ? "sin cambios claros" : events).
            t shoulder_pan shoulder_lift elbow_flex wrist_flex wrist_roll gripper
            \(table)
            """])
        }
        for p in m.pictures {
            content.append(["type": "text", "text": "Demostración \(p.episode), \(p.label):"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": p.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": "Estudia todo y escribe el paquete con write_package."])
        return content
    }

    /// Arma el paquete con lo que escribió la IA; las poses salen de las trayectorias reales (no de números copiados).
    static func package(from input: [String: Any], material m: StudyMaterial) -> KnowledgePackage {
        let byEpisode = Dictionary(uniqueKeysWithValues: m.episodes.map { ($0.index, $0.trajectory) })
        func strings(_ key: String, _ item: [String: Any]) -> String { item[key] as? String ?? "" }
        func number(_ key: String, _ item: [String: Any]) -> Double { (item[key] as? NSNumber)?.doubleValue ?? 0 }
        let poses = (input["poses"] as? [[String: Any]] ?? []).compactMap { p -> KnowledgePackage.Pose? in
            let e = Int(number("episode", p)), at = number("at_s", p)
            guard let traj = byEpisode[e], let row = traj.min(by: { abs($0[0] - at) < abs($1[0] - at) }), row.count == 7 else { return nil }
            return .init(name: strings("name", p), joints: Dictionary(uniqueKeysWithValues: zip(RealAgentTools.joints, row.dropFirst())),
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
            trajectories: Dictionary(uniqueKeysWithValues: m.episodes.map { (String($0.index), $0.trajectory) }),
            pictures: m.pictures.prefix(4).map { .init(label: "Demostración \($0.episode), \($0.label)", jpeg: $0.jpeg) })
    }

    // MARK: - En vivo

    /// Lo que se agrega al prompt del robot en vivo cuando hay un paquete activo.
    static func liveSection(_ k: KnowledgePackage) -> String {
        let stages = k.stages.enumerated().map { "\($0.offset + 1). \($0.element.name): \($0.element.goal) — se logró si: \($0.element.check)" }
        let poses = k.poses.map { p in
            "- «\(p.name)»: " + RealAgentTools.joints.map { "\($0) \(RealAgentTools.format(p.joints[$0] ?? 0, $0))" }.joined(separator: ", ") + (p.note.isEmpty ? "" : " (\(p.note))")
        }
        let segments = k.segments.map { "- «\($0.name)»: demostración \($0.episode), de \($0.from) a \($0.to) s\($0.note.isEmpty ? "" : " (\($0.note))")" }
        return """

        Estudiaste demostraciones de esta tarea (\(k.source)). Tu paquete de conocimiento:
        \(k.summary)

        Etapas:
        \(stages.joined(separator: "\n"))

        Poses guardadas (go_to_pose):
        \(poses.joined(separator: "\n"))

        Tramos para reproducir (play_segment):
        \(segments.joined(separator: "\n"))

        Consejos: \(k.tips.joined(separator: " · "))

        Cómo usarlo: sigue las etapas; para cada una, recupera la pose o el tramo que corresponda, adáptalo a \
        lo que ves (offsets de unos grados si el objeto está en otro lugar que en las demostraciones), \
        ejecútalo y comprueba con la cámara la prueba de esa etapa antes de seguir. Las demostraciones pueden \
        venir de otro robot igual con otra calibración: trátalas como referencia, no como verdad exacta.
        """
    }

    static let liveTools: [[String: Any]] = [
        [
            "name": "go_to_pose", "strict": true,
            "description": "Lleva el robot a una pose guardada del paquete de conocimiento, con ajustes opcionales en grados. Requiere aprobación.",
            "input_schema": ["type": "object", "additionalProperties": false, "required": ["name", "offsets"],
                             "properties": ["name": ["type": "string"], "offsets": offsets]] as [String: Any],
        ],
        [
            "name": "play_segment", "strict": true,
            "description": "Reproduce en el robot un tramo de una demostración del paquete (primero va despacio a su inicio). speed de 0.25 a 1 (por defecto 0.5). Requiere aprobación.",
            "input_schema": ["type": "object", "additionalProperties": false, "required": ["name", "speed", "offsets"],
                             "properties": ["name": ["type": "string"], "speed": ["type": "number"], "offsets": offsets]] as [String: Any],
        ],
    ]

    private static let offsets: [String: Any] = [
        "type": "array",
        "description": "Ajustes a sumar a cada punto, en grados (pinza en 0-100). Vacío si no hace falta.",
        "items": ["type": "object", "additionalProperties": false, "required": ["joint", "delta"],
                  "properties": ["joint": ["type": "string", "enum": RealAgentTools.joints], "delta": ["type": "number"]]],
    ]
}
