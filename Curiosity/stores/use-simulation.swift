import Foundation
import Observation

/// La simulación del robot abierto: carga, estado en vivo y órdenes (de la persona o de la IA).
@Observable
final class UseSimulation {
    let engine = SimulationQueries()

    private(set) var engineReady = false
    private(set) var loadingText: String?
    private(set) var error: String?
    private(set) var model: RobotModel?
    private(set) var state = SimulationState()
    private(set) var objects: [SceneObject] = []
    private(set) var log: [String] = []
    private(set) var speed = 1.0
    private(set) var activeCamera: String?
    var physics = PhysicsSettings() { didSet { engine.setPhysics(physics) } }

    private var loadedRobotID: String?

    init() {
        engine.onMessage = { [weak self] message in self?.handle(message) }
    }

    func open(_ robot: Robot, profile: [String: Any]) {
        guard loadedRobotID != robot.id else { return }
        loadedRobotID = robot.id
        model = nil
        error = nil
        objects = []
        activeCamera = nil
        loadingText = "Abriendo \(robot.name)…"
        engine.load(url: SimulationQueries.modelURL(for: robot), profile: profile)
    }

    // MARK: - Controles

    func togglePause() { engine.pause(!state.paused); state.paused.toggle() }
    func step() { engine.step(10) }
    func reset() { engine.reset() }
    func setSpeed(_ x: Double) { speed = x; engine.setSpeed(x) }
    func view(_ name: String) { engine.view(name) }

    func showCamera(_ name: String?) {
        activeCamera = name
        engine.showCamera(name)
    }

    /// Objetivo de una articulación en unidades del motor (rad o m).
    func setTarget(_ joint: String, _ value: Double) {
        engine.setTarget(joint, value)
        if let i = state.joints.firstIndex(where: { $0.name == joint }) { state.joints[i].target = value }
    }

    func setGains(_ joint: String, kp: Double? = nil, kd: Double? = nil, fmax: Double? = nil) {
        engine.setGains(joint, kp: kp, kd: kd, fmax: fmax)
        guard var m = model, let i = m.joints.firstIndex(where: { $0.name == joint }) else { return }
        if let kp { m.joints[i].kp = kp }
        if let kd { m.joints[i].kd = kd }
        if let fmax { m.joints[i].fmax = fmax }
        model = m
    }

    @discardableResult
    func addObject(_ object: SceneObject) async throws -> Int {
        let id = try await engine.addObject([
            "shape": object.shape, "size": object.size, "mass": object.mass, "color": object.color,
            "pos": object.pos, "yaw": object.yaw, "fixed": object.fixed, "name": object.name,
        ])
        var added = object
        added.id = id
        objects.append(added)
        return id
    }

    func removeObject(_ id: Int) {
        engine.removeObject(id)
        objects.removeAll { $0.id == id }
    }

    func capture(camera: String?) async throws -> Data { try await engine.capture(camera: camera) }

    /// Deja correr la simulación `seconds` segundos de tiempo simulado (o hasta 3× eso de reloj).
    func run(seconds: Double) async {
        if state.paused { togglePause() }
        let start = state.time, deadline = Date().addingTimeInterval(seconds * 3 + 0.5)
        while state.time - start < seconds && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Mensajes del motor

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready":
            engineReady = true
        case "loading":
            loadingText = m["text"] as? String
        case "error":
            loadingText = nil
            error = m["text"] as? String
        case "log":
            if let text = m["text"] as? String { log.append(text) }
        case "model":
            loadingText = nil
            model = Self.parseModel(m)
            objects = model?.objects ?? []
        case "state":
            let next = Self.parseState(m)
            if next != state { state = next }
        default:
            break
        }
    }

    private static func parseModel(_ m: [String: Any]) -> RobotModel {
        let joints = (m["joints"] as? [[String: Any]] ?? []).map { j in
            JointInfo(name: j["name"] as? String ?? "", type: j["type"] as? String ?? "revolute",
                      lower: (j["lower"] as? NSNumber)?.doubleValue, upper: (j["upper"] as? NSNumber)?.doubleValue,
                      effort: double(j["effort"]), kp: double(j["kp"]), kd: double(j["kd"]), fmax: double(j["fmax"]))
        }
        let objects = (m["objects"] as? [[String: Any]] ?? []).map(parseObject)
        return RobotModel(name: m["name"] as? String ?? "robot", links: m["links"] as? [String] ?? [],
                          joints: joints, cameras: m["cameras"] as? [String] ?? [], objects: objects,
                          warnings: m["warnings"] as? [String] ?? [])
    }

    private static func parseObject(_ o: [String: Any]) -> SceneObject {
        SceneObject(id: (o["id"] as? NSNumber)?.intValue ?? 0, shape: o["shape"] as? String ?? "box",
                    size: (o["size"] as? [NSNumber])?.map(\.doubleValue) ?? [], mass: double(o["mass"]),
                    color: o["color"] as? String ?? "#cccccc", pos: (o["pos"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0],
                    yaw: double(o["yaw"]), fixed: o["fixed"] as? Bool ?? false, name: o["name"] as? String ?? "")
    }

    private static func parseState(_ m: [String: Any]) -> SimulationState {
        var s = SimulationState()
        s.time = double(m["t"])
        s.realTimeFactor = double(m["rtf"])
        s.paused = m["paused"] as? Bool ?? false
        s.contacts = (m["contacts"] as? NSNumber)?.intValue ?? 0
        s.maxForce = double(m["maxForce"])
        s.joints = (m["joints"] as? [[String: Any]] ?? []).map {
            JointState(name: $0["name"] as? String ?? "", q: double($0["q"]), qd: double($0["qd"]),
                       target: double($0["target"]), force: double($0["force"]))
        }
        for o in m["objects"] as? [[String: Any]] ?? [] {
            if let id = (o["id"] as? NSNumber)?.intValue { s.objectPositions[id] = (o["pos"] as? [NSNumber])?.map(\.doubleValue) }
        }
        return s
    }

    private static func double(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
}
