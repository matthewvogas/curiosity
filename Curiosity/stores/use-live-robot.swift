import Foundation
import Observation

/// El robot real en vivo: conectarlo (se queda firme), moverlo con los controles o con la IA, y soltarlo
/// (vuelve a su pose del principio). Tiene un gemelo 3D que copia su pose, ve por todas sus cámaras y es
/// también el cuerpo del chat con el robot real.
@Observable
final class UseLiveRobot {
    let lerobot: UseLeRobot
    private let knowledge: UseKnowledge
    /// Objetivos de los deslizadores aún sin mandar (se juntan para no saturar el puente).
    private var outgoing: [String: Double] = [:]
    private var flushing = false
    private(set) var device: Device?
    /// El modelo 3D del robot (el que se eligió en sus ajustes), quieto, puesto en la misma pose que el real.
    let twin = SimulationQueries()
    private var twinLoaded = false
    private var twinModelID: String?
    /// El rango de cada articulación del modelo 3D, para llevar ahí lo que no va en grados.
    private var twinRanges: [String: (lower: Double?, upper: Double?)] = [:]
    /// Los últimos movimientos (antes, después y cuánto cambió), para que la IA entienda cómo responde.
    private var moves: [[String: Any]] = []
    /// Calibrando una cámara (su nombre) y los pares marcados hasta ahora (ver live-arm).
    var calibrating: String?
    var calibrationPairs: [CameraCalibration.Pair] = []
    /// Adónde va la pinza en cada punto de la calibración (m, base del robot), según su espacio de trabajo.
    var calibrationTargets: [[Double]] = []
    /// Cómo es el brazo según el ejecutor sobre el modelo 3D (para describírselo a la IA).
    private var twinArm: [String: Any]?
    /// Lo que está haciendo el brazo solo (una habilidad o ir a un punto) y el último problema.
    var armBusy: String?
    var armError: String?
    /// El tamaño de la última foto que vio la IA por cada cámara (para pasar sus píxeles a la mesa).
    var lookSizes: [String: (width: Int, height: Int)] = [:]

    init(lerobot: UseLeRobot, knowledge: UseKnowledge) {
        self.lerobot = lerobot
        self.knowledge = knowledge
        twin.onAttach = { [weak self] in Task { @MainActor in self?.loadTwin() } }
        twin.onMessage = { [weak self] m in
            guard let self, m["type"] as? String == "model" else { return }
            self.twin.pause(true)   // sin física: solo copia la pose
            self.twinRanges = Dictionary((m["joints"] as? [[String: Any]] ?? []).compactMap { j in
                (j["name"] as? String).map { ($0, ((j["lower"] as? NSNumber)?.doubleValue, (j["upper"] as? NSNumber)?.doubleValue)) }
            }) { a, _ in a }
            self.twinLoaded = true
            self.mirror(self.lerobot.session?.joints ?? [:], units: self.lerobot.session?.units ?? [:])
            Task { self.twinArm = try? await self.twin.effector() }
        }
        // El modelo 3D copia al robot en vivo y también mientras prueba un modelo. La IA usa sus articulaciones.
        lerobot.onSession = { [weak self] s in
            guard s.kind == "live" || s.kind == "rollout" else { return }
            if !s.jointNames.isEmpty {
                RealAgentTools.joints = s.jointNames
                RealAgentTools.units = s.units
            }
            self?.mirror(s.joints, units: s.units)
        }
    }

    /// Las cámaras en vivo, con su nombre: la principal primero.
    var cameras: [(key: String, name: String, frame: Data?)] {
        guard isLive, let device else { return [] }
        var out = [("front", device.cameraName ?? "Main", lerobot.frames["front"])]
        for (i, extra) in lerobot.extraCameras(device).enumerated() {
            out.append(("cam\(i + 1)", extra.name, lerobot.frames["cam\(i + 1)"]))
        }
        return out
    }

    private func label(_ key: String) -> String { cameras.first { $0.key == key }?.name ?? key }

    /// El modelo 3D que se eligió para este robot (de los incluidos o importados); sin ninguno no hay gemelo.
    var hasTwin: Bool { twinModel != nil }

    private var twinModel: Robot? {
        guard let id = device?.model, !id.isEmpty else { return nil }
        return (RobotQueries.bundled() + RobotQueries.imported()).first { $0.id == id }
    }

    private func loadTwin() {
        twinLoaded = false
        guard let robot = twinModel, let url = RobotQueries.fileURL(for: robot) else { return }
        twinModelID = robot.id
        var profile = RobotQueries.readProfile(urdfURL: url)
        profile["scene"] = ["objects": []]   // solo el robot, sin los objetos de la escena
        twin.load(url: SimulationQueries.modelURL(for: robot), profile: profile)
    }

    /// Una posición de LeRobot → la del modelo 3D (nil si el modelo no tiene esa articulación).
    func toTwin(_ joint: String, _ value: Double) -> Double? {
        guard let range = twinRanges[joint] else { return nil }
        return JointUnits.toModel(value, unit: lerobot.session?.units[joint] ?? RealAgentTools.units[joint] ?? "deg",
                                  lower: range.lower, upper: range.upper)
    }

    /// Una posición del modelo 3D → la de LeRobot.
    func fromTwin(_ joint: String, _ q: Double) -> Double? {
        guard let range = twinRanges[joint] else { return nil }
        return JointUnits.fromModel(q, unit: lerobot.session?.units[joint] ?? RealAgentTools.units[joint] ?? "deg",
                                    lower: range.lower, upper: range.upper)
    }

    /// Las posiciones de LeRobot → las del modelo 3D, por nombre de articulación (las que no tiene se ignoran).
    func mirror(_ joints: [String: Double], units: [String: String]? = nil) {
        guard twinLoaded, !joints.isEmpty else { return }
        let units = units ?? lerobot.session?.units ?? [:]
        let q = joints.reduce(into: [String: Double]()) { out, j in
            guard let range = twinRanges[j.key],
                  let v = JointUnits.toModel(j.value, unit: units[j.key] ?? "deg", lower: range.lower, upper: range.upper) else { return }
            out[j.key] = v
        }
        if !q.isEmpty { twin.setTargets(q, snap: true) }
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
        if twinModelID != nil, twinModelID != device.model { loadTwin() }
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

    // MARK: - Modelo de órdenes (la IA dice «qué», el modelo hace el «cómo»)

    var skillModel: SkillModel? { isLive ? lerobot.session?.skillModel : nil }
    var skillRun: SkillRun? { isLive ? lerobot.session?.skill : nil }
    var skillLast: SkillResult? { isLive ? lerobot.session?.skillLast : nil }
    private(set) var skillLoading = false
    private(set) var skillError: String?
    /// Si la IA del chat puede usar el modelo (run_skill) o solo se prueba a mano.
    var skillForAI = UserDefaults.standard.object(forKey: "live.skillForAI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skillForAI, forKey: "live.skillForAI") }
    }

    func loadSkill(_ path: String) async {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        skillLoading = true
        skillError = nil
        defer { skillLoading = false }
        do { try await lerobot.liveSkillLoad(path) } catch { skillError = error.localizedDescription }
    }

    /// Corre una orden y espera a que termine (por tiempo, al pararla o si la cortan los controles).
    @discardableResult
    func runSkill(_ instruction: String, seconds: Double) async throws -> SkillResult? {
        skillError = nil
        let before = skillLast
        do { try await lerobot.liveSkill(instruction, seconds: seconds) } catch { skillError = error.localizedDescription; throw error }
        // El primer aviso puede tardar: el modelo piensa su primer tramo antes de que el bucle avise.
        let deadline = Date().addingTimeInterval(seconds + 20)
        var started = false
        while isLive, Date() < deadline {
            if Task.isCancelled { stopSkill(); break }
            if skillRun != nil {
                started = true
            } else if let last = skillLast, started || last != before {
                return last
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return skillLast
    }

    func stopSkill() { Task { try? await lerobot.liveSkillStop() } }

    /// El estado para la IA: articulaciones y dónde quedó la pinza (cinemática directa del modelo 3D).
    private func pose() async -> [String: Any] {
        var out = RealAgentTools.describe(joints: joints, targets: targets, limits: limits)
        if twinLoaded {
            try? await Task.sleep(for: .milliseconds(150))  // que el gemelo alcance la última pose
        }
        // Dónde está el centro del agarre, con la cinemática del modelo 3D (sirve para cualquier brazo).
        if twinLoaded, let tip = try? await twin.tip() { out["gripper_cm"] = tip.map { ($0 * 1000).rounded() / 10 } }
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
    func settle(timeout: Double, waitPlayback: Bool = false) async {
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
            + (skillModel != nil && skillForAI ? [RealAgentTools.runSkill] : [])
            + RealAgentTools.armTools
    }
    var chatNotReady: String { "Connect the robot live to talk to it." }

    /// Lo medido para la IA: el brazo y la pinza (del modelo 3D) y cada cámara con su calibración.
    var chatRobotFacts: [String]? {
        guard isReady else { return nil }
        let cams = cameras.map { c in
            calibration(c.name).map { "\(c.name) (calibrated, error \(String(format: "%.1f", $0.errorPx)) px)" }
                ?? "\(c.name) (not calibrated: look only)"
        }
        return RobotNotes.facts(effector: twinArm, cameras: cams)
    }

    func chatSystemPrompt(robotName: String) -> String? {
        guard isReady else { return nil }
        let calibrated = cameras.map(\.name).filter { calibration($0) != nil }
        return RealAgentTools.systemPrompt(robotName: robotName, limits: limits, calibratedCameras: calibrated)
            + (knowledge.active.map(KnowledgePrompt.liveSection) ?? "")
            + (skillForAI ? skillModel.map(RealAgentTools.skillSection) ?? "" : "")
    }

    func chatTitle(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "go_to_pose": "Go to \"\(input["name"] as? String ?? "")\""
        case "play_segment": "Play \"\(input["name"] as? String ?? "")\""
        case "look_references": "Looking at the demonstration pictures"
        case "pick": "Pick up"
        case "place": "Put it down"
        case "gripper": (input["open"] as? Bool ?? true) ? "Open the gripper" : "Close the gripper"
        default: RealAgentTools.title(for: name)
        }
    }

    func chatApproval(_ name: String, _ input: [String: Any]) -> String? {
        let offsets = Self.offsets(input)
        let extra = offsets.isEmpty ? "" : "\nAdjustments: " + offsets.map { "\($0.key) \($0.value >= 0 ? "+" : "")\(RealAgentTools.format($0.value, $0.key))" }.joined(separator: ", ")
        switch name {
        case "go_to_pose":
            guard let pose = knowledge.active?.poses.first(where: { $0.name == input["name"] as? String }) else { return nil }
            return RealAgentTools.joints.map { j in "\(j): \(RealAgentTools.format(joints[j] ?? 0, j)) → \(RealAgentTools.format((pose.joints[j] ?? 0) + (offsets[j] ?? 0), j))" }
                .joined(separator: "\n") + extra
        case "play_segment":
            guard let s = knowledge.active?.segments.first(where: { $0.name == input["name"] as? String }) else { return nil }
            let speed = Self.speed(input)
            return "Demonstration \(s.episode), from \(s.from) to \(s.to) s, at \(Int(speed * 100))% of its speed\(s.note.isEmpty ? "" : " (\(s.note))")." + extra
        case "pick":
            let camera = input["camera"] as? String ?? ""
            let spot = (try? pickTarget(camera: camera, input: input).get())
                .map { " → table point (\(Int(($0.point[0] * 100).rounded())), \(Int(($0.point[1] * 100).rounded()))) cm, \(String(format: "%.1f", $0.width * 100)) cm wide" } ?? ""
            return "The arm picks up what's between \(AgentTools.pixel(input, "finger_a")) and \(AgentTools.pixel(input, "finger_b")) of \(camera)\(spot), turning the gripper to match, in one continuous move."
        case "place":
            let x = (input["x"] as? NSNumber)?.doubleValue ?? 0, y = (input["y"] as? NSNumber)?.doubleValue ?? 0
            let camera = input["camera"] as? String ?? ""
            let h = ((input["surface_cm"] as? NSNumber)?.doubleValue ?? 0) / 100
            let spot = (try? tablePoint(camera: camera, x: x, y: y, height: h).get())
                .map { " → table point (\(Int(($0[0] * 100).rounded())), \(Int(($0[1] * 100).rounded()))) cm" } ?? ""
            return "The arm puts it down at pixel (\(Int(x)), \(Int(y))) of \(camera)\(spot), in one continuous move."
        case "gripper":
            return (input["open"] as? Bool ?? true) ? "Open the gripper." : "Close the gripper."
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

    /// La foto de una cámara calibrada va con cuadrícula y su tamaño, para poder señalar en ella.
    private func gridded(camera: String, jpeg: Data) -> (label: String, jpeg: Data) {
        guard calibration(camera) != nil, let g = ImageGrid.draw(jpeg) else { return (camera, jpeg) }
        lookSizes[camera] = (g.width, g.height)
        return ("\(camera) (\(g.width)×\(g.height) px, calibrated: you can point in it)", g.jpeg)
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
        return .text(AgentTools.json(out), problem: clipped.isEmpty ? nil : "Clamped to range: \(clipped.joined(separator: ", "))")
    }

    func chatRun(_ name: String, _ input: [String: Any]) async throws -> ChatToolOutput {
        guard isReady else { throw NSError(domain: "Curiosity", code: 9, userInfo: [NSLocalizedDescriptionKey: "The robot is no longer live."]) }
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
                return .text("There's no pose with that name.", problem: "Unknown pose")
            }
            let target = pose.joints.merging(Self.offsets(input)) { $0 + $1 }
            let (clamped, clipped) = clamp(target)
            return try await perform(clamped, clipped: clipped)

        case "play_segment":
            guard let s = knowledge.active?.segments.first(where: { $0.name == input["name"] as? String }),
                  let traj = knowledge.active?.trajectories[String(s.episode)] else {
                return .text("There's no segment with that name.", problem: "Unknown segment")
            }
            let offsets = Self.offsets(input), speed = Self.speed(input)
            // Las columnas de la trayectoria siguen el orden del dataset; el robot espera el suyo.
            let order = knowledge.active?.jointOrder ?? []
            let points = traj.filter { $0[0] >= s.from - 0.01 && $0[0] <= s.to + 0.01 }.map { row in
                [row[0]] + RealAgentTools.joints.map { j in
                    (order.firstIndex(of: j).map { row[$0 + 1] } ?? joints[j] ?? 0) + (offsets[j] ?? 0)
                }
            }
            guard let last = points.last else { return .text("The segment is empty.", problem: "Empty segment") }
            let end = Dictionary(uniqueKeysWithValues: zip(RealAgentTools.joints, last.dropFirst()))
            return try await perform(clamp(end).0, play: {
                try await self.lerobot.liveTrajectory(points, speed: speed)
                return (s.to - s.from) / speed + 2
            })

        case "look_references":
            return .images((knowledge.active?.pictures ?? []).map { ($0.label, $0.jpeg) })

        case "run_skill":
            guard skillModel != nil else { return .text("No action model is loaded.", problem: "No model") }
            let instruction = input["instruction"] as? String ?? ""
            let ended = try await withTaskCancellationHandler {
                try await runSkill(instruction, seconds: RealAgentTools.clampSkillSeconds(input))
            } onCancel: { Task { @MainActor in self.stopSkill() } }
            var out = await pose()
            out["result"] = ended.map { ["reason": $0.reason, "seconds": $0.seconds] as [String: Any] } ?? ["reason": "unknown"]
            let photos = (try? await lerobot.liveLook())?.map { (label: label($0.camera), jpeg: $0.jpeg) } ?? []
            let failed = ended?.reason.hasPrefix("error") == true
            return .report(AgentTools.json(out), photos: photos, problem: failed ? ended?.reason : nil)

        case "pick", "place", "gripper":
            var spec: [String: Any] = ["type": name]
            if name == "gripper" {
                spec["open"] = input["open"] as? Bool ?? true
            } else {
                let camera = input["camera"] as? String ?? ""
                let height = ((input["height_cm"] as? NSNumber)?.doubleValue ?? 2.5) / 100
                let surface = ((input["surface_cm"] as? NSNumber)?.doubleValue ?? 0) / 100
                spec["height"] = height
                spec["surface"] = surface
                if name == "pick" {
                    // Dónde va cada dedo: el medio es el centro del agarre; la línea entre ellos, hacia dónde cierran.
                    switch pickTarget(camera: camera, input: input) {
                    case .failure(let problem): return .text(problem.message, problem: "Can't locate it")
                    case .success(let t):
                        spec["point"] = t.point
                        spec["yaw"] = t.yaw
                        spec["width"] = t.width
                    }
                } else {
                    // Al dejar, se señala la superficie donde va.
                    let x = (input["x"] as? NSNumber)?.doubleValue ?? 0, y = (input["y"] as? NSNumber)?.doubleValue ?? 0
                    switch tablePoint(camera: camera, x: x, y: y, height: surface) {
                    case .failure(let problem): return .text(problem.message, problem: "Can't locate it")
                    case .success(let point): spec["point"] = point
                    }
                }
            }
            let outcome = try await withTaskCancellationHandler {
                await runSkill(spec, busy: chatTitle(name, input) + "…")
            } onCancel: { [lerobot] in Task { @MainActor in try? await lerobot.liveTargets([:]) } }
            let photos = try await lerobot.liveLook()
            var images = photos.map { gridded(camera: label($0.camera), jpeg: $0.jpeg) }
            if twinLoaded, let model = try? await twin.capture(camera: nil) { images.append(("3D model (replica in the robot's current pose)", model)) }
            let failed = outcome["done"] as? Bool != true
            return .report(AgentTools.json(outcome), photos: images, problem: failed ? outcome["message"] as? String : nil)

        case "look":
            let photos = try await lerobot.liveLook()
            var images = photos.map { gridded(camera: label($0.camera), jpeg: $0.jpeg) }
            // El modelo 3D en la misma pose: muestra la forma del brazo aunque las cámaras no lo vean entero.
            if twinLoaded, let model = try? await twin.capture(camera: nil) {
                images.append(("3D model (replica in the robot's current pose)", model))
            }
            return .images(images)

        case "go_home":
            try await lerobot.liveHome()
            await settle(timeout: 8)
            return .text(AgentTools.json(await pose()))

        default:
            return .text("Unknown tool: \(name)", problem: "Unknown tool")
        }
    }
}
