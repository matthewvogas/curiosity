import Foundation
import Observation

/// El robot real en vivo: conectarlo (se queda firme), moverlo con los controles o con la IA, y soltarlo
/// (vuelve a su pose del principio). Tiene un gemelo 3D que copia su pose, ve por todas sus cámaras y es
/// también el cuerpo del chat con el robot real.
@Observable
final class UseLiveRobot {
    private let lerobot: UseLeRobot
    /// Objetivos de los deslizadores aún sin mandar (se juntan para no saturar el puente).
    private var outgoing: [String: Double] = [:]
    private var flushing = false
    private var device: Device?
    /// El SO-101 del simulador, quieto, puesto en la misma pose que el real.
    let twin = SimulationQueries()
    private var twinLoaded = false
    /// Los últimos movimientos (antes, después y cuánto cambió), para que la IA entienda cómo responde.
    private var moves: [[String: Any]] = []

    init(lerobot: UseLeRobot) {
        self.lerobot = lerobot
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

    /// Espera a que el robot llegue a sus objetivos (o se acabe el tiempo).
    private func settle(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(400))
        while Date() < deadline, isLive {
            let t = targets, q = joints
            if RealAgentTools.joints.allSatisfy({ abs((q[$0] ?? 0) - (t[$0] ?? 0)) < 3 }) { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

extension UseLiveRobot: ChatBody {
    var chatTools: [[String: Any]] { RealAgentTools.definitions }
    var chatNotReady: String { "Conecta el robot en vivo para hablar con él." }

    func chatSystemPrompt(robotName: String) -> String? {
        isReady ? RealAgentTools.systemPrompt(robotName: robotName, limits: limits) : nil
    }

    func chatTitle(_ name: String, _ input: [String: Any]) -> String { RealAgentTools.title(for: name) }

    func chatApproval(_ name: String, _ input: [String: Any]) -> String? {
        RealAgentTools.approval(for: name, input: input, current: joints)
    }

    func chatRun(_ name: String, _ input: [String: Any]) async throws -> ChatToolOutput {
        guard isReady else { throw NSError(domain: "Curiosity", code: 9, userInfo: [NSLocalizedDescriptionKey: "El robot ya no está en vivo."]) }
        switch name {
        case "get_state":
            var out = await pose()
            if !moves.isEmpty { out["previous_moves"] = Array(moves.suffix(3)) }
            return .text(AgentTools.json(out))

        case "move_joints":
            var batch: [String: Double] = [:], clipped: [String] = []
            var longest = 0.0
            for t in input["targets"] as? [[String: Any]] ?? [] {
                guard let j = t["joint"] as? String, let v = (t["value"] as? NSNumber)?.doubleValue, let range = limits[j] else { continue }
                let value = min(range.upperBound, max(range.lowerBound, v))
                if value != v { clipped.append(j) }
                batch[j] = value
                longest = max(longest, abs(value - (joints[j] ?? value)))
            }
            let before = await pose()
            let start = joints
            try await lerobot.liveTargets(batch)
            await settle(timeout: longest / 40 + 2)
            let after = await pose()
            let end = joints
            let move = RealAgentTools.move(asked: batch, start: start, end: end, before: before["gripper_cm"], after: after["gripper_cm"])
            var out: [String: Any] = ["move": move, "now": after]
            if !moves.isEmpty { out["previous_moves"] = Array(moves.suffix(3)) }
            moves = Array((moves + [move]).suffix(5))
            if !clipped.isEmpty { out["clipped_to_limits"] = clipped }
            return .text(AgentTools.json(out), problem: clipped.isEmpty ? nil : "Ajustado al rango: \(clipped.joined(separator: ", "))")

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
