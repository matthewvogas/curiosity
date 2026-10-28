import Foundation
import Observation

/// El robot real en vivo: conectarlo (se queda firme), moverlo con los controles o con la IA, y soltarlo
/// (vuelve a su pose del principio). Tiene un gemelo 3D que copia su pose, ve por todas sus cámaras y es
/// también el cuerpo del chat con el robot real.
@Observable
final class UseLiveRobot {
    private let lerobot: UseLeRobot
    private let knowledge: UseKnowledge
    /// Objetivos de los deslizadores aún sin mandar (se juntan para no saturar el puente).
    private var outgoing: [String: Double] = [:]
    private var flushing = false
    private var device: Device?
    /// El SO-101 del simulador, quieto, puesto en la misma pose que el real.
    let twin = SimulationQueries()
    private var twinLoaded = false
    /// Los últimos movimientos (antes, después y cuánto cambió), para que la IA entienda cómo responde.
    private var moves: [[String: Any]] = []

    init(lerobot: UseLeRobot, knowledge: UseKnowledge) {
        self.lerobot = lerobot
        self.knowledge = knowledge
        twin.onAttach = { [weak self] in Task { @MainActor in self?.loadTwin() } }
        twin.onMessage = { [weak self] m in
            guard let self, m["type"] as? String == "model" else { return }
            self.twin.pause(true)   // sin física: solo copia la pose
            self.twinLoaded = true
            self.mirror(self.joints)
        }
        lerobot.onSession = { [weak self] s in if s.kind == "live" { self?.mirror(s.joints) } }
    }

    /// Las cámaras en vivo, con su nombre: la principal primero.
    var cameras: [(key: String, name: String, frame: Data?)] {
        guard isLive, let device else { return [] }
        var out = [("front", device.cameraName ?? "Principal", lerobot.frames["front"])]
        for (i, extra) in lerobot.extraCameras(device).enumerated() {
            out.append(("cam\(i + 1)", extra.name, lerobot.frames["cam\(i + 1)"]))
        }
        return out
    }

    private func label(_ key: String) -> String { cameras.first { $0.key == key }?.name ?? key }

    private func loadTwin() {
        twinLoaded = false
        guard let so101 = RobotQueries.bundled().first(where: { $0.id == "bundled.so101" }), let url = RobotQueries.fileURL(for: so101) else { return }
        var profile = RobotQueries.readProfile(urdfURL: url)
        profile["scene"] = ["objects": []]   // solo el brazo, sin los objetos de la escena
        twin.load(url: SimulationQueries.modelURL(for: so101), profile: profile)
    }

    /// Grados de LeRobot → radianes del URDF (la pinza, de 0–100 a su rango), como en el visor anterior.
    private func mirror(_ joints: [String: Double]) {
        guard twinLoaded, !joints.isEmpty else { return }
        let q = joints.mapValues { $0 * .pi / 180 }.merging(["gripper": (joints["gripper"] ?? 0) / 100 * 1.74533]) { $1 }
        twin.setTargets(q, snap: true)
    }

    var isLive: Bool { lerobot.session?.kind == "live" && lerobot.session?.active == true }
    var isReturning: Bool { isLive && lerobot.session?.phase == "returning" }
    var isReady: Bool { isLive && lerobot.session?.phase == "running" }
    var joints: [String: Double] { isLive ? lerobot.session?.joints ?? [:] : [:] }
    var targets: [String: Double] { isLive ? (lerobot.session?.targets ?? [:]).merging(outgoing) { $1 } : [:] }
    var limits: [String: ClosedRange<Double>] { isLive ? lerobot.session?.limits ?? [:] : [:] }

    /// Las cámaras extra cambiaron mientras está en vivo (para nombrarlas bien).
    func update(_ device: Device) { self.device = device }

    func start(_ device: Device) async {
        self.device = device
        moves = []
        await lerobot.live(device)
    }
    func stop() { lerobot.stop() }

    /// Desde un deslizador: el último valor de cada articulación, como mucho cada 50 ms.
    func setTarget(_ joint: String, _ value: Double) {
        outgoing[joint] = value
        guard !flushing else { return }
        flushing = true
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let batch = outgoing
            outgoing = [:]
            flushing = false
            try? await lerobot.liveTargets(batch)
        }
    }

    /// Cambia las cámaras extra sin desconectar el robot.
    func setExtraCameras(_ device: Device) {
        self.device = device
        let indexes = lerobot.extraCameras(device).map(\.index)
        Task { try? await lerobot.liveCameras(indexes) }
    }

    func home() { Task { try? await lerobot.liveHome() } }

    /// El estado para la IA: articulaciones y dónde quedó la pinza (cinemática directa del modelo 3D).
    private func pose() async -> [String: Any] {
        var out = RealAgentTools.describe(joints: joints, targets: targets, limits: limits)
        if twinLoaded {
            try? await Task.sleep(for: .milliseconds(150))  // que el gemelo alcance la última pose
        }
        if twinLoaded, let fresh = try? await twin.linkPositions() {
            if let g = fresh["gripper_frame_link"] ?? fresh["gripper_link"] { out["gripper_cm"] = g.map { ($0 * 1000).rounded() / 10 } }
            if let w = fresh["wrist_link"] { out["wrist_cm"] = w.map { ($0 * 1000).rounded() / 10 } }
        }
        return out
    }

    private func clamp(_ batch: [String: Double]) -> ([String: Double], [String]) {
        var out: [String: Double] = [:], clipped: [String] = []
        for (j, v) in batch {
            guard let range = limits[j] else { continue }
            let value = min(range.upperBound, max(range.lowerBound, v))
            if value != v { clipped.append(j) }
            out[j] = value
        }
        return (out, clipped)
    }

    /// Espera a que el robot llegue a sus objetivos (o termine de reproducir, o se acabe el tiempo).
    private func settle(timeout: Double, waitPlayback: Bool = false) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(400))
        while waitPlayback, Date() < deadline, isLive, lerobot.session?.playing == true {
            try? await Task.sleep(for: .milliseconds(200))
        }
        while Date() < deadline, isLive {
            let t = targets, q = joints
            if RealAgentTools.joints.allSatisfy({ abs((q[$0] ?? 0) - (t[$0] ?? 0)) < 3 }) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

extension UseLiveRobot: ChatBody {
    var chatTools: [[String: Any]] {
        RealAgentTools.definitions + (knowledge.active == nil ? [] : KnowledgePrompt.liveTools + [RealAgentTools.lookReferences])
    }
    var chatNotReady: String { "Conecta el robot en vivo para hablar con él." }

    func chatSystemPrompt(robotName: String) -> String? {
        guard isReady else { return nil }
        return RealAgentTools.systemPrompt(robotName: robotName, limits: limits)
            + (knowledge.active.map(KnowledgePrompt.liveSection) ?? "")
    }

    func chatTitle(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "go_to_pose": "Ir a «\(input["name"] as? String ?? "")»"
        case "play_segment": "Reproducir «\(input["name"] as? String ?? "")»"
        case "look_references": "Mirando las fotos de las demostraciones"
        default: RealAgentTools.title(for: name)
        }
    }

    func chatApproval(_ name: String, _ input: [String: Any]) -> String? {
        let offsets = Self.offsets(input)
        let extra = offsets.isEmpty ? "" : "\nAjustes: " + offsets.map { "\($0.key) \($0.value >= 0 ? "+" : "")\(RealAgentTools.format($0.value, $0.key))" }.joined(separator: ", ")
        switch name {
        case "go_to_pose":
            guard let pose = knowledge.active?.poses.first(where: { $0.name == input["name"] as? String }) else { return nil }
            return RealAgentTools.joints.map { j in "\(j): \(RealAgentTools.format(joints[j] ?? 0, j)) → \(RealAgentTools.format((pose.joints[j] ?? 0) + (offsets[j] ?? 0), j))" }
                .joined(separator: "\n") + extra
        case "play_segment":
            guard let s = knowledge.active?.segments.first(where: { $0.name == input["name"] as? String }) else { return nil }
            let speed = Self.speed(input)
            return "Demostración \(s.episode), de \(s.from) a \(s.to) s, a \(Int(speed * 100)) % de su velocidad\(s.note.isEmpty ? "" : " (\(s.note))")." + extra
        default:
            return RealAgentTools.approval(for: name, input: input, current: joints)
        }
    }

    private static func offsets(_ input: [String: Any]) -> [String: Double] {
        (input["offsets"] as? [[String: Any]] ?? []).reduce(into: [:]) { out, o in
            if let j = o["joint"] as? String, let d = (o["delta"] as? NSNumber)?.doubleValue, d != 0 { out[j] = d }
        }
    }

    private static func speed(_ input: [String: Any]) -> Double {
        min(1, max(0.25, (input["speed"] as? NSNumber)?.doubleValue ?? 0.5))
    }

    /// Mueve a `batch` y devuelve el antes y el después (como move_joints).
    private func perform(_ batch: [String: Double], clipped: [String] = [], play: (() async throws -> Double)? = nil) async throws -> ChatToolOutput {
        let before = await pose()
        let start = joints
        if let play {
            let duration = try await play()
            await settle(timeout: duration + 3, waitPlayback: true)
        } else {
            try await lerobot.liveTargets(batch)
            let longest = batch.map { abs($0.value - (start[$0.key] ?? $0.value)) }.max() ?? 0
            await settle(timeout: longest / 40 + 2)
        }
        let after = await pose()
        let move = RealAgentTools.move(asked: batch, start: start, end: joints, before: before["gripper_cm"], after: after["gripper_cm"])
        var out: [String: Any] = ["move": move, "now": after]
        if !moves.isEmpty { out["previous_moves"] = Array(moves.suffix(3)) }
        moves = Array((moves + [move]).suffix(5))
        if !clipped.isEmpty { out["clipped_to_limits"] = clipped }
        return .text(AgentTools.json(out), problem: clipped.isEmpty ? nil : "Ajustado al rango: \(clipped.joined(separator: ", "))")
    }

    func chatRun(_ name: String, _ input: [String: Any]) async throws -> ChatToolOutput {
        guard isReady else { throw NSError(domain: "Curiosity", code: 9, userInfo: [NSLocalizedDescriptionKey: "El robot ya no está en vivo."]) }
        switch name {
        case "get_state":
            var out = await pose()
            if !moves.isEmpty { out["previous_moves"] = Array(moves.suffix(3)) }
            return .text(AgentTools.json(out))

        case "move_joints":
            var batch: [String: Double] = [:]
            for t in input["targets"] as? [[String: Any]] ?? [] {
                if let j = t["joint"] as? String, let v = (t["value"] as? NSNumber)?.doubleValue { batch[j] = v }
            }
            let (clamped, clipped) = clamp(batch)
            return try await perform(clamped, clipped: clipped)

        case "go_to_pose":
            guard let pose = knowledge.active?.poses.first(where: { $0.name == input["name"] as? String }) else {
                return .text("No hay una pose con ese nombre.", problem: "Pose desconocida")
            }
            let target = pose.joints.merging(Self.offsets(input)) { $0 + $1 }
            let (clamped, clipped) = clamp(target)
            return try await perform(clamped, clipped: clipped)

        case "play_segment":
            guard let s = knowledge.active?.segments.first(where: { $0.name == input["name"] as? String }),
                  let traj = knowledge.active?.trajectories[String(s.episode)] else {
                return .text("No hay un tramo con ese nombre.", problem: "Tramo desconocido")
            }
            let offsets = Self.offsets(input), speed = Self.speed(input)
            let points = traj.filter { $0[0] >= s.from - 0.01 && $0[0] <= s.to + 0.01 }.map { row in
                [row[0]] + RealAgentTools.joints.enumerated().map { i, j in row[i + 1] + (offsets[j] ?? 0) }
            }
            guard let last = points.last else { return .text("El tramo está vacío.", problem: "Tramo vacío") }
            let end = Dictionary(uniqueKeysWithValues: zip(RealAgentTools.joints, last.dropFirst()))
            return try await perform(clamp(end).0, play: {
                try await self.lerobot.liveTrajectory(points, speed: speed)
                return (s.to - s.from) / speed + 2
            })

        case "look_references":
            return .images((knowledge.active?.pictures ?? []).map { ($0.label, $0.jpeg) })

        case "look":
            let photos = try await lerobot.liveLook()
            var images = photos.map { (label: label($0.camera), jpeg: $0.jpeg) }
            // El modelo 3D en la misma pose: muestra la forma del brazo aunque las cámaras no lo vean entero.
            if twinLoaded, let model = try? await twin.capture(camera: nil) {
                images.append(("Modelo 3D (réplica en la pose actual del robot)", model))
            }
            return .images(images)

        case "go_home":
            try await lerobot.liveHome()
            await settle(timeout: 8)
            return .text(AgentTools.json(await pose()))

        default:
            return .text("Herramienta desconocida: \(name)", problem: "Herramienta desconocida")
        }
    }
}
