import AppKit
import Observation

/// La simulación del robot abierto: carga, estado en vivo y órdenes (de la persona o de la IA).
@Observable
final class UseSimulation {
    let engine = SimulationQueries()
    /// La API key y el modelo, para crear objetos con IA.
    private let settings: UseSettings

    private(set) var engineReady = false
    private(set) var loadingText: String?
    private(set) var error: String?
    private(set) var model: RobotModel?
    private(set) var state = SimulationState()
    private(set) var objects: [SceneObject] = []
    private(set) var speed = 1.0
    private(set) var activeCamera: String?
    var physics = PhysicsSettings() { didSet { engine.setPhysics(physics) } }
    var render = RenderOptions() { didSet { engine.setRender(render) } }
    private(set) var keyframes: [Keyframe] = []
    /// Aviso corto tras una acción (captura guardada, estado copiado…).
    private(set) var notice: String?

    private var loadedRobotID: String?
    private var current: (robot: Robot, profile: [String: Any])?

    /// Vistas fijas alrededor de la escena (lados y esquinas), para mirar y para que la IA vea lo que la cámara
    /// de arriba no ve. Se eligen en el menú de vista y se recuerdan entre robots.
    static let viewAngles: [(name: String, azimuth: Double)] = [
        ("Front", 0), ("Front-left", 45), ("Left", 90), ("Back-left", 135),
        ("Back", 180), ("Back-right", -135), ("Right", -90), ("Front-right", -45),
    ]
    var views = Set(UserDefaults.standard.stringArray(forKey: "sim.views") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(views), forKey: "sim.views")
            Task { await placeViews() }
        }
    }
    private var rootLink: String?
    private var modelCameras: [String] = []
    private var placedViews: [String] = []
    /// Cómo es el brazo (del ejecutor del motor) y dónde va cada cámara: para describirle el robot a la IA.
    private var armInfo: [String: Any]?
    private var cameraLinks: [String: String] = [:]

    init(settings: UseSettings) {
        self.settings = settings
        engine.onMessage = { [weak self] message in self?.handle(message) }
        // Un visor nuevo empieza vacío: se le vuelve a cargar el robot abierto.
        engine.onAttach = { [weak self] in Task { @MainActor in self?.reload() } }  // fuera de la actualización de la vista
    }

    func open(_ robot: Robot, profile: [String: Any], force: Bool = false) {
        guard force || loadedRobotID != robot.id else { return }
        loadedRobotID = robot.id
        current = (robot, profile)
        keyframes = RobotQueries.keyframes(robotID: robot.id)
        model = nil
        error = nil
        objects = []
        activeCamera = nil
        loadingText = "Opening \(robot.name)…"
        engine.load(url: SimulationQueries.modelURL(for: robot), profile: profile)
    }

    // MARK: - Controles

    func togglePause() { engine.pause(!state.paused); state.paused.toggle() }
    /// Vuelve a leer el URDF y su perfil desde el disco (para ver cambios hechos fuera).
    func reload() { if let c = current { open(c.robot, profile: c.profile, force: true) } }
    func align() { engine.view("tres") }

    /// Todas las articulaciones al objetivo cero (el «Clear all» de MuJoCo).
    func clearControls() {
        for j in model?.actuatedJoints ?? [] {
            let zero = j.lower.map { lo in min(j.upper ?? 0, max(lo, 0)) } ?? 0
            setTarget(j.name, zero)
        }
    }

    // MARK: - Keyframes, copiar estado, captura

    func saveKeyframe() async {
        guard let robot = current?.robot, let json = try? await engine.keyframe() else { return }
        keyframes.append(Keyframe(name: "Pose \(keyframes.count + 1)", json: json))
        persistKeyframes(robot)
        flash("Pose saved")
    }

    func loadKeyframe(_ key: Keyframe) { engine.setKeyframe(json: key.json) }

    func deleteKeyframe(_ key: Keyframe) {
        guard let robot = current?.robot else { return }
        keyframes.removeAll { $0.id == key.id }
        persistKeyframes(robot)
    }

    func copyState() async {
        guard let json = try? await engine.keyframe() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        flash("State copied")
    }

    func screenshot() async {
        guard let robot = current?.robot else { return }
        do {
            let png = try await engine.capture(camera: nil, width: 2400, png: true)
            let url = try RobotQueries.saveScreenshot(png, robotName: robot.name)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            flash("Screenshot saved to Pictures")
        } catch {
            flash(error.localizedDescription)
        }
    }

    /// Resumen del modelo en texto («Print model» de MuJoCo).
    var modelSummary: String {
        guard let m = model else { return "" }
        var lines = ["Model: \(m.name)", "Links: \(m.links.count) · Moving joints: \(m.joints.count) · Mass: \(String(format: "%.3f", m.mass)) kg", ""]
        lines.append("Links")
        lines += m.links.map { "  \($0)" }
        lines.append("")
        lines.append("Joints (type · range · kp · kd · max force)")
        for j in m.joints {
            let range = (j.lower != nil && j.upper != nil)
                ? "\(Units.format(j.lower!, jointType: j.type)) … \(Units.format(j.upper!, jointType: j.type))" : "unlimited"
            lines.append("  \(j.name) · \(j.type) · \(range) · \(String(format: "%.1f · %.2f · %.1f", j.kp, j.kd, j.fmax))")
        }
        if !m.cameras.isEmpty { lines += ["", "Cameras: " + m.cameras.joined(separator: ", ")] }
        if !m.warnings.isEmpty { lines += ["", "Warnings"] + m.warnings.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }

    private func persistKeyframes(_ robot: Robot) {
        try? RobotQueries.saveKeyframes(keyframes, robotID: robot.id)
    }

    private func flash(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }
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
        if state.paused { togglePause() }  // mover un control es pedirle que corra
    }

    func setGains(_ joint: String, kp: Double? = nil, kd: Double? = nil, fmax: Double? = nil) {
        engine.setGains(joint, kp: kp, kd: kd, fmax: fmax)
        guard var m = model, let i = m.joints.firstIndex(where: { $0.name == joint }) else { return }
        if let kp { m.joints[i].kp = kp }
        if let kd { m.joints[i].kd = kd }
        if let fmax { m.joints[i].fmax = fmax }
        model = m
    }

    /// Pone un objeto en la escena. Con `drop`, el motor elige un lugar libre y lo suelta desde un poco más arriba.
    @discardableResult
    func addObject(_ object: SceneObject, drop: Bool = false) async throws -> Int {
        var spec: [String: Any] = [
            "shape": object.shape, "size": object.size, "mass": object.mass, "color": object.color,
            "yaw": object.yaw, "fixed": object.fixed, "name": object.name,
        ]
        if !drop { spec["pos"] = object.pos }
        if let euler = object.euler { spec["euler"] = euler }
        if let parts = object.parts {
            spec["parts"] = parts.map { ["shape": $0.shape, "size": $0.size, "pos": $0.pos, "euler": $0.euler, "color": $0.color] }
        }
        if drop { spec["drop"] = true }
        return try await addObject(spec: spec).id
    }

    /// Pone un objeto a partir de su especificación para el motor; devuelve su id y cómo quedó.
    private func addObject(spec: [String: Any]) async throws -> (id: Int, object: SceneObject) {
        let id = try await engine.addObject(spec)
        var added = Self.parseObject(spec)
        added.id = id
        // Si lo ubicó el motor, se pregunta dónde quedó.
        if spec["pos"] == nil, let pose = (try? await engine.objectPoses())?[id] { added.pos = pose.pos }
        objects.append(added)
        return (id, added)
    }

    /// Un objeto nuevo a partir de una descripción («una rueda», «un escritorio», «un cuchillo»): la IA lo arma
    /// con piezas simples en tamaño y peso reales, y se suelta en un lugar libre de la mesa.
    func designObject(_ description: String) async throws -> (id: Int, object: SceneObject) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Self.failure("Describe the object first.") }
        guard let key = settings.anthropicKey else { throw Self.failure("Add your Claude API key in Settings to create objects with AI.") }
        let response = try await AnthropicQueries.createMessage(apiKey: key, body: ObjectDesigner.request(description: text, model: settings.modelID))
        let added = try await addObject(spec: try ObjectDesigner.parse(response))
        flash("Added \(added.object.name)")
        return added
    }

    /// Cambia un objeto de la escena: moverlo o girarlo (queda quieto ahí y la física sigue), o su peso, color,
    /// nombre y si está fijo. `changes` en unidades del motor: {pos (m), yaw o euler (grados), mass, color, name, fixed}.
    func updateObject(_ id: Int, _ changes: [String: Any]) async {
        var changes = changes
        // Un objeto con giro completo: el nuevo giro alrededor de z conserva los otros dos.
        if let yaw = changes["yaw"] as? Double, let e = objects.first(where: { $0.id == id })?.euler, e.count == 3 {
            changes["yaw"] = nil
            changes["euler"] = [e[0], e[1], yaw]
        }
        guard (try? await engine.updateObject(id, changes)) == true, let i = objects.firstIndex(where: { $0.id == id }) else { return }
        var o = objects[i]
        if let pos = changes["pos"] as? [Double] { o.pos = pos }
        if let yaw = changes["yaw"] as? Double { o.yaw = yaw; o.euler = nil }
        if let euler = changes["euler"] as? [Double] { o.euler = euler }
        if let mass = changes["mass"] as? Double { o.mass = mass }
        if let name = changes["name"] as? String { o.name = name }
        if let fixed = changes["fixed"] as? Bool { o.fixed = fixed }
        if let color = changes["color"] as? String {
            o.color = color
            // Un color nuevo pinta todas las piezas (como en el motor).
            o.parts = o.parts?.map { var p = $0; p.color = color; return p }
        }
        objects[i] = o
    }

    /// Dónde está y cómo está girado un objeto ahora (m en el marco de la base, grados alrededor de z).
    func objectPose(_ id: Int) async -> (pos: [Double], yaw: Double)? {
        (try? await engine.objectPoses())?[id]
    }

    func removeObject(_ id: Int) {
        engine.removeObject(id)
        objects.removeAll { $0.id == id }
    }

    func capture(camera: String?, grid: Bool = false) async throws -> Data { try await engine.capture(camera: camera, grid: grid) }
    func cameraSize(_ camera: String) async throws -> (width: Int, height: Int) { try await engine.cameraSize(camera) }

    /// Una habilidad del ejecutor (agarrar, dejar, abrir la pinza…): corre sola y devuelve cómo salió.
    func skill(_ spec: [String: Any]) async throws -> [String: Any] {
        if state.paused { togglePause() }
        return try await withTaskCancellationHandler {
            try await engine.skill(spec)
        } onCancel: { [engine] in
            Task { @MainActor in engine.cancelSkill() }
        }
    }

    /// Deja correr la simulación `seconds` segundos de tiempo simulado (o hasta 3× eso de reloj).
    func run(seconds: Double) async {
        if state.paused { togglePause() }
        let start = state.time, deadline = Date().addingTimeInterval(seconds * 3 + 0.5)
        while state.time - start < seconds && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Mensajes del motor

    /// Pone las vistas elegidas alrededor de lo que hay en escena (las piezas del robot y los objetos), a una
    /// distancia que lo deja entero en la imagen. Van en la base del robot: son cámaras fijas, como «Overhead».
    func placeViews() async {
        guard model != nil, let root = rootLink else { return }
        for name in placedViews { engine.removeCamera(name) }
        placedViews = []
        if !views.isEmpty, let links = try? await engine.linkPositions() {
            let points = Array(links.values) + state.objectPositions.values.compactMap { $0 }
            let lo = (0..<3).map { i in points.map { $0[i] }.min() ?? 0 }
            let hi = (0..<3).map { i in points.map { $0[i] }.max() ?? 0 }
            let center = (0..<3).map { (lo[$0] + hi[$0]) / 2 }
            let radius = max(0.15, sqrt((0..<3).map { pow((hi[$0] - lo[$0]) / 2, 2) }.reduce(0, +)))
            let fovy = 55.0, elevation = 35.0 * .pi / 180
            let distance = radius / tan(fovy / 2 * .pi / 180) * 1.15
            for (name, azimuth) in Self.viewAngles where views.contains(name) {
                let a = azimuth * .pi / 180
                let dir = [cos(elevation) * cos(a), cos(elevation) * sin(a), sin(elevation)]
                let camera = "\(name) view"
                engine.addCamera(["name": camera, "link": root, "pos": (0..<3).map { center[$0] + dir[$0] * distance },
                                  "quat": Self.lookQuat(back: dir), "fovy": fovy, "width": 640, "height": 480])
                placedViews.append(camera)
            }
        }
        model?.cameras = modelCameras + placedViews
        if let active = activeCamera, !(model?.cameras.contains(active) ?? false) { showCamera(nil) }
    }

    /// La orientación de una cámara de MuJoCo (mira hacia −z, y arriba) cuyo −z apunta en contra de `back`
    /// (unitario), con la vertical hacia arriba. Cuaternión [x, y, z, w].
    private static func lookQuat(back z: [Double]) -> [Double] {
        func cross(_ a: [Double], _ b: [Double]) -> [Double] { [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]] }
        func unit(_ v: [Double]) -> [Double] { let n = sqrt(v.map { $0 * $0 }.reduce(0, +)); return v.map { $0 / n } }
        let x = unit(cross([0, 0, 1], z)), y = cross(z, x)
        // Matriz de rotación con columnas x, y, z → cuaternión.
        let (m00, m11, m22) = (x[0], y[1], z[2])
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = sqrt(trace + 1) * 2
            return [(y[2] - z[1]) / s, (z[0] - x[2]) / s, (x[1] - y[0]) / s, s / 4]
        } else if m00 > m11 && m00 > m22 {
            let s = sqrt(1 + m00 - m11 - m22) * 2
            return [s / 4, (y[0] + x[1]) / s, (z[0] + x[2]) / s, (y[2] - z[1]) / s]
        } else if m11 > m22 {
            let s = sqrt(1 + m11 - m00 - m22) * 2
            return [(y[0] + x[1]) / s, s / 4, (z[1] + y[2]) / s, (z[0] - x[2]) / s]
        } else {
            let s = sqrt(1 + m22 - m00 - m11) * 2
            return [(z[0] + x[2]) / s, (z[1] + y[2]) / s, s / 4, (x[1] - y[0]) / s]
        }
    }

    /// Lo medido del robot para la IA (brazo, pinza, cámaras); nil hasta que el modelo está cargado.
    var robotFacts: [String]? {
        guard model != nil else { return nil }
        let cameras = (model?.cameras ?? []).map { name -> String in
            let link = cameraLinks[name]
            return link == nil || link == rootLink ? "\(name) (fixed)" : "\(name) (on \(link!))"
        }
        return RobotNotes.facts(effector: armInfo, cameras: cameras)
    }

    private func handle(_ m: [String: Any]) {
        switch m["type"] as? String {
        case "ready":
            engineReady = true
        case "loading":
            loadingText = m["text"] as? String
        case "error":
            loadingText = nil
            error = m["text"] as? String
        case "model":
            loadingText = nil
            model = Self.parseModel(m)
            objects = model?.objects ?? []
            rootLink = m["root"] as? String
            modelCameras = model?.cameras ?? []
            placedViews = []   // al cargar, el motor empieza sin las vistas
            armInfo = nil
            cameraLinks = [:]
            Task {
                await placeViews()
                armInfo = try? await engine.effector()
                cameraLinks = Dictionary(((try? await engine.cameraInfo()) ?? []).compactMap { c in
                    (c["name"] as? String).map { ($0, c["link"] as? String ?? "") }
                }) { a, _ in a }
            }
            // Abre quieto: la física corre cuando la persona le da a reproducir (o cuando la IA lo mueve).
            engine.pause(true)
            state.paused = true
            engine.setRender(render)
            engine.setPhysics(physics)
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
                      effort: double(j["effort"]), kp: double(j["kp"]), kd: double(j["kd"]), fmax: double(j["fmax"]),
                      actuated: j["actuated"] as? Bool ?? true, mimic: j["mimic"] as? String)
        }
        let objects = (m["objects"] as? [[String: Any]] ?? []).map(parseObject)
        return RobotModel(name: m["name"] as? String ?? "robot", links: m["links"] as? [String] ?? [],
                          joints: joints, cameras: m["cameras"] as? [String] ?? [], objects: objects,
                          warnings: m["warnings"] as? [String] ?? [], mass: double(m["mass"]), floating: m["floating"] as? Bool ?? false)
    }

    private static func parseObject(_ o: [String: Any]) -> SceneObject {
        SceneObject(id: (o["id"] as? NSNumber)?.intValue ?? 0, shape: o["shape"] as? String ?? "box",
                    size: (o["size"] as? [NSNumber])?.map(\.doubleValue) ?? [], mass: double(o["mass"]),
                    color: o["color"] as? String ?? "#cccccc", pos: (o["pos"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0],
                    yaw: double(o["yaw"]), fixed: o["fixed"] as? Bool ?? false, name: o["name"] as? String ?? "",
                    parts: (o["parts"] as? [[String: Any]])?.map(parsePart),
                    euler: (o["euler"] as? [NSNumber])?.map(\.doubleValue))
    }

    private static func parsePart(_ p: [String: Any]) -> ObjectPart {
        ObjectPart(shape: p["shape"] as? String ?? "box", size: (p["size"] as? [NSNumber])?.map(\.doubleValue) ?? [],
                   pos: (p["pos"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0],
                   euler: (p["euler"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 0], color: p["color"] as? String ?? "#9a9a9f")
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "Curiosity", code: 8, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static func parseState(_ m: [String: Any]) -> SimulationState {
        var s = SimulationState()
        s.time = double(m["t"])
        s.realTimeFactor = double(m["rtf"])
        s.paused = m["paused"] as? Bool ?? false
        s.contacts = (m["contacts"] as? NSNumber)?.intValue ?? 0
        s.maxForce = double(m["maxForce"])
        s.stepMs = double(m["stepMs"])
        for l in m["links"] as? [[String: Any]] ?? [] {
            if let name = l["name"] as? String { s.linkForces[name] = double(l["force"]) }
        }
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
