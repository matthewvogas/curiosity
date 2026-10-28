import AppKit
import Observation

/// LeRobot para los robots reales: el puente, lo que hay instalado (calibraciones, cámaras) y lo que
/// corre con el robot (teleoperar, grabar, probar un modelo). Nada mueve el robot sin una orden.
@Observable
final class UseLeRobot {
    enum Status: Equatable { case off, starting, ready, failed(String) }

    private let settings: UseSettings
    private let bridge = BridgeQueries()

    private(set) var status: Status = .off
    private(set) var env: LeRobotEnv?
    private(set) var calibrations = Calibrations()
    private(set) var cameras: [CameraInfo] = []
    private(set) var session: RobotSession?
    /// Lo que ve la cámara del robot mientras se graba o corre un modelo (JPEG).
    /// El último cuadro de la cámara principal y, en vivo, el de cada cámara («front», «cam1»…).
    private(set) var frame: Data?
    private(set) var frames: [String: Data] = [:]
    /// Avisa cada estado de una sesión (en vivo lo usa el modelo 3D que copia al robot).
    var onSession: (RobotSession) -> Void = { _ in }
    private(set) var error: String?

    var isBusy: Bool { session?.active == true }

    init(settings: UseSettings) {
        self.settings = settings
        bridge.onEvent = { [weak self] in self?.handle($0) }
        bridge.onExit = { [weak self] reason in
            guard let self else { return }
            if self.status == .ready { self.status = .failed(reason) }
            if self.session?.active == true { self.session?.active = false; self.session?.error = reason }
        }
    }

    /// Arranca el puente (si no está) y lee lo instalado. Tarda unos segundos la primera vez.
    func start() async {
        guard status != .starting, !bridge.isRunning else { return }
        status = .starting
        do {
            try await bridge.start(python: settings.lerobotPython, hubToken: settings.hubToken)
            status = .ready
            await refresh()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        do {
            let hello = try await bridge.request("hello")
            env = LeRobotEnv(version: hello["lerobot"] as? String ?? "?", hubUser: hello["hf_user"] as? String,
                             smolvla: hello["smolvla"] as? Bool ?? false)
            let calib = try await bridge.request("calibrations")
            calibrations = Calibrations(robots: calib["robots"] as? [String: [String]] ?? [:],
                                        teleoperators: calib["teleoperators"] as? [String: [String]] ?? [:])
            refreshCameras()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Vuelve a buscar cámaras (por si se enchufó una).
    func refreshCameras() {
        let found = CameraQueries.list()
        if found != cameras { cameras = found }
    }

    /// Revisa cada pieza sin mover nada: permiso de cámara, follower, leader (si `withLeader`), poses y cámara.
    func preflight(_ d: Device, withLeader: Bool, withExtras: Bool = false) async -> (checks: [PreflightCheck], picture: Data?) {
        refreshCameras()
        if status != .ready { await start() }
        guard await PermissionQueries.camera() else {
            return ([PreflightCheck(key: "permission", state: .fail,
                                    detail: "Curiosity doesn't have permission to use the camera. Turn it on in System Settings.")], nil)
        }
        var args = base(d).merging(["camera": camera(d)]) { $1 }
        if withLeader { args.merge(leader(d)) { $1 } }
        if withExtras { args["extra_cameras"] = extraCameras(d).map(\.index) }
        do {
            let r = try await bridge.request("preflight", args)
            let checks = (r["checks"] as? [[String: Any]] ?? []).compactMap { c -> PreflightCheck? in
                guard let key = c["key"] as? String, let state = (c["state"] as? String).flatMap(PreflightCheck.State.init) else { return nil }
                return PreflightCheck(key: key, state: state, detail: c["detail"] as? String ?? "")
            }
            return (checks, (r["jpeg"] as? String).flatMap { Data(base64Encoded: $0) })
        } catch {
            return ([PreflightCheck(key: "bridge", state: .fail, detail: LeRobotErrors.friendly(error.localizedDescription))], nil)
        }
    }

    /// Una foto de la cámara, para elegir la correcta (no usa el robot).
    func snapshot(_ index: Int) async -> Data? {
        do {
            let r = try await bridge.request("snapshot", ["index": index])
            return (r["jpeg"] as? String).flatMap { Data(base64Encoded: $0) }
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Datasets en esas carpetas (crudo, para UseDatasets).
    func datasets(roots: [String]) async throws -> [[String: Any]] {
        let r = try await bridge.request("datasets", ["roots": roots])
        return r["datasets"] as? [[String: Any]] ?? []
    }

    func request(_ cmd: String, _ args: [String: Any]) async throws -> [String: Any] {
        try await bridge.request(cmd, args)
    }

    // MARK: - Con el robot

    /// El follower copia al leader.
    func teleoperate(_ d: Device) async {
        await startSession("teleop", base(d).merging(leader(d)) { $1 }.merging(["fps": 60]) { $1 })
    }

    /// Graba demostraciones con el leader en un dataset de la app.
    func record(_ d: Device, dataset: String, task: String, episodes: Int, episodeSeconds: Double, resetSeconds: Double) async {
        refreshCameras()
        let root = AppPaths.datasets.appendingPathComponent(dataset).path
        await startSession("record", base(d).merging(leader(d)) { $1 }.merging([
            "camera": camera(d), "repo_id": "local/\(dataset)", "root": root, "task": task,
            "num_episodes": episodes, "episode_time_s": episodeSeconds, "reset_time_s": resetSeconds,
        ]) { $1 })
    }

    /// El robot usa un modelo entrenado durante `seconds`.
    func runPolicy(_ d: Device, modelPath: String, task: String, seconds: Double) async {
        refreshCameras()
        await startSession("rollout", base(d).merging([
            "camera": camera(d), "policy_path": modelPath, "task": task, "duration": seconds, "max_relative_target": 10,
        ]) { $1 })
    }

    /// En vivo: el follower se queda firme y va a los objetivos que se le manden (sin leader).
    func live(_ d: Device) async {
        refreshCameras()
        await startSession("live", base(d).merging(["camera": camera(d), "extra_cameras": extraCameras(d).map(\.index)]) { $1 })
    }

    func liveTargets(_ targets: [String: Double]) async throws { _ = try await bridge.request("live_targets", ["targets": targets]) }
    func liveCameras(_ indexes: [Int]) async throws { _ = try await bridge.request("live_cameras", ["extra_cameras": indexes]) }
    /// Reproduce una trayectoria ([[t, articulaciones…]] en grados) a `speed` de su velocidad.
    func liveTrajectory(_ points: [[Double]], speed: Double) async throws {
        _ = try await bridge.request("live_trajectory", ["points": points, "speed": speed])
    }
    func liveHome() async throws { _ = try await bridge.request("live_home") }

    /// Una foto grande de cada cámara mientras está en vivo (para la IA): [(cámara, JPEG)].
    func liveLook() async throws -> [(camera: String, jpeg: Data)] {
        let r = try await bridge.request("live_look")
        let photos = (r["images"] as? [[String: Any]] ?? []).compactMap { i -> (camera: String, jpeg: Data)? in
            guard let c = i["camera"] as? String, let d = (i["jpeg"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return nil }
            return (c, d)
        }
        guard !photos.isEmpty else {
            throw NSError(domain: "Curiosity", code: 8, userInfo: [NSLocalizedDescriptionKey: "The cameras didn't send an image."])
        }
        return photos
    }

    /// Demostraciones en la simulación: el leader real mueve el robot simulado; el follower no se conecta.
    func simRecord(leader d: Device, dataset: String, task: String, episodes: Int, episodeSeconds: Double, resetSeconds: Double) async {
        let root = AppPaths.datasets.appendingPathComponent(dataset).path
        await startSession("simrecord", leader(d).merging([
            "follower_id": d.followerID ?? "", "repo_id": "local/\(dataset)", "root": root, "task": task,
            "num_episodes": episodes, "episode_time_s": episodeSeconds, "reset_time_s": resetSeconds, "fps": 30,
        ]) { $1 })
    }

    /// Un cuadro de la simulación para la grabación: la imagen de su cámara y su estado (grados; pinza 0-100).
    func simFrame(jpeg: Data, state: [String: Double]) async {
        _ = try? await bridge.request("sim_frame", ["jpeg": jpeg.base64EncodedString(), "state": state])
    }

    func next() { Task { _ = try? await bridge.request("next") } }
    func redo() { Task { _ = try? await bridge.request("redo") } }
    func stop() { Task { _ = try? await bridge.request("stop") } }

    // MARK: - Interno

    private func base(_ d: Device) -> [String: Any] { ["follower_port": d.id, "follower_id": d.followerID ?? ""] }
    private func leader(_ d: Device) -> [String: Any] { ["leader_port": d.leaderPort ?? "", "leader_id": d.leaderID ?? ""] }
    private func camera(_ d: Device) -> [String: Any] { ["index": mainCamera(d) ?? 0, "width": 640, "height": 480, "fps": 30] }

    /// El número actual de la cámara principal. Se busca por nombre: macOS renumera las cámaras al enchufar otra.
    func mainCamera(_ d: Device) -> Int? {
        cameras.first { $0.name == d.cameraName }?.index ?? d.cameraIndex
    }

    /// Las cámaras extra enchufadas ahora, con su número actual (sin repetir la principal).
    func extraCameras(_ d: Device) -> [(name: String, index: Int)] {
        let main = mainCamera(d)
        return d.extraNames.compactMap { name in
            cameras.first { $0.name == name && $0.index != main }.map { (name, $0.index) }
        }
    }

    private func startSession(_ kind: String, _ args: [String: Any]) async {
        error = nil
        frame = nil
        frames = [:]
        if status != .ready { await start() }
        guard status == .ready else { return }
        session = RobotSession(kind: kind, phase: "starting", active: true)
        do {
            try await bridge.request(kind, args)
        } catch {
            session = nil
            self.error = error.localizedDescription
        }
    }

    private func handle(_ e: [String: Any]) {
        guard let kind = e["event"] as? String else { return }
        if kind == "frame" {
            let data = (e["jpeg"] as? String).flatMap { Data(base64Encoded: $0) }
            let camera = e["camera"] as? String ?? "front"
            frames[camera] = data
            if camera == "front" { frame = data }
            return
        }
        guard ["teleop", "record", "rollout", "live", "simrecord"].contains(kind) else { return }
        var s = RobotSession(kind: kind, phase: e["phase"] as? String ?? "", active: e["active"] as? Bool ?? false)
        s.error = e["error"] as? String
        s.hz = (e["hz"] as? NSNumber)?.doubleValue ?? 0
        s.joints = (e["joints"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        s.episode = (e["episode"] as? NSNumber)?.intValue ?? 0
        s.target = (e["target"] as? NSNumber)?.intValue ?? 0
        s.elapsed = (e["elapsed"] as? NSNumber)?.doubleValue ?? 0
        s.limit = (e["limit"] as? NSNumber)?.doubleValue ?? 0
        s.targets = (e["targets"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        s.playing = e["playing"] as? Bool ?? false
        s.limits = (e["limits"] as? [String: [NSNumber]] ?? [:]).compactMapValues { v in
            v.count == 2 && v[0].doubleValue <= v[1].doubleValue ? v[0].doubleValue...v[1].doubleValue : nil
        }
        if s != session { session = s; onSession(s) }
        // Si terminó por un error, que se vea y diga qué hacer.
        if !s.active, let raw = s.error { error = LeRobotErrors.friendly(raw) }
    }
}
