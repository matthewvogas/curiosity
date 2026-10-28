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
    private(set) var frame: Data?
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

    func restart() async {
        bridge.stop()
        try? await Task.sleep(for: .seconds(1))
        status = .off
        await start()
    }

    func refresh() async {
        do {
            let hello = try await bridge.request("hello")
            env = LeRobotEnv(version: hello["lerobot"] as? String ?? "?", hubUser: hello["hf_user"] as? String,
                             smolvla: hello["smolvla"] as? Bool ?? false)
            let calib = try await bridge.request("calibrations")
            calibrations = Calibrations(robots: calib["robots"] as? [String: [String]] ?? [:],
                                        teleoperators: calib["teleoperators"] as? [String: [String]] ?? [:])
            let cams = try await bridge.request("cameras")
            cameras = (cams["cameras"] as? [[String: Any]] ?? []).compactMap { c in
                guard let i = c["index"] as? Int, let n = c["name"] as? String else { return nil }
                return CameraInfo(index: i, name: n)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Revisa cada pieza sin mover nada: permiso de cámara, follower, leader (si `withLeader`), poses y cámara.
    func preflight(_ d: Device, withLeader: Bool) async -> (checks: [PreflightCheck], picture: Data?) {
        if status != .ready { await start() }
        guard await PermissionQueries.camera() else {
            return ([PreflightCheck(key: "permission", state: .fail,
                                    detail: "Curiosity no tiene permiso para usar la cámara. Actívalo en Ajustes del Sistema.")], nil)
        }
        var args = base(d).merging(["camera": camera(d)]) { $1 }
        if withLeader { args.merge(leader(d)) { $1 } }
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
        let root = AppPaths.datasets.appendingPathComponent(dataset).path
        await startSession("record", base(d).merging(leader(d)) { $1 }.merging([
            "camera": camera(d), "repo_id": "local/\(dataset)", "root": root, "task": task,
            "num_episodes": episodes, "episode_time_s": episodeSeconds, "reset_time_s": resetSeconds,
        ]) { $1 })
    }

    /// El robot usa un modelo entrenado durante `seconds`.
    func runPolicy(_ d: Device, modelPath: String, task: String, seconds: Double) async {
        await startSession("rollout", base(d).merging([
            "camera": camera(d), "policy_path": modelPath, "task": task, "duration": seconds, "max_relative_target": 10,
        ]) { $1 })
    }

    /// En vivo: el follower se queda firme y va a los objetivos que se le manden (sin leader).
    func live(_ d: Device) async {
        await startSession("live", base(d).merging(["camera": camera(d)]) { $1 })
    }

    func liveTargets(_ targets: [String: Double]) async throws { _ = try await bridge.request("live_targets", ["targets": targets]) }
    func liveHome() async throws { _ = try await bridge.request("live_home") }

    /// Una foto grande de la cámara mientras está en vivo (para la IA).
    func liveLook() async throws -> Data {
        let r = try await bridge.request("live_look")
        guard let jpeg = (r["jpeg"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw NSError(domain: "Curiosity", code: 8, userInfo: [NSLocalizedDescriptionKey: "La cámara no entregó imagen."])
        }
        return jpeg
    }

    func next() { Task { _ = try? await bridge.request("next") } }
    func redo() { Task { _ = try? await bridge.request("redo") } }
    func stop() { Task { _ = try? await bridge.request("stop") } }

    // MARK: - Interno

    private func base(_ d: Device) -> [String: Any] { ["follower_port": d.id, "follower_id": d.followerID ?? ""] }
    private func leader(_ d: Device) -> [String: Any] { ["leader_port": d.leaderPort ?? "", "leader_id": d.leaderID ?? ""] }
    private func camera(_ d: Device) -> [String: Any] { ["index": d.cameraIndex ?? 0, "width": 640, "height": 480, "fps": 30] }

    private func startSession(_ kind: String, _ args: [String: Any]) async {
        error = nil
        frame = nil
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
            frame = (e["jpeg"] as? String).flatMap { Data(base64Encoded: $0) }
            return
        }
        guard ["teleop", "record", "rollout", "live"].contains(kind) else { return }
        var s = RobotSession(kind: kind, phase: e["phase"] as? String ?? "", active: e["active"] as? Bool ?? false)
        s.error = e["error"] as? String
        s.hz = (e["hz"] as? NSNumber)?.doubleValue ?? 0
        s.joints = (e["joints"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        s.episode = (e["episode"] as? NSNumber)?.intValue ?? 0
        s.target = (e["target"] as? NSNumber)?.intValue ?? 0
        s.elapsed = (e["elapsed"] as? NSNumber)?.doubleValue ?? 0
        s.limit = (e["limit"] as? NSNumber)?.doubleValue ?? 0
        s.targets = (e["targets"] as? [String: NSNumber])?.mapValues(\.doubleValue) ?? [:]
        s.limits = (e["limits"] as? [String: [NSNumber]] ?? [:]).compactMapValues { v in
            v.count == 2 && v[0].doubleValue <= v[1].doubleValue ? v[0].doubleValue...v[1].doubleValue : nil
        }
        if s != session { session = s }
        // Si terminó por un error, que se vea y diga qué hacer.
        if !s.active, let raw = s.error { error = LeRobotErrors.friendly(raw) }
    }
}
