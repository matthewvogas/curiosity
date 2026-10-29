import Foundation

/// El «cerebro del brazo» con el robot real: el mismo ejecutor del simulador (skills.js), corriendo sobre el
/// gemelo 3D con los límites de la calibración. Planifica la trayectoria entera y el robot la hace de una vez;
/// la IA solo dice qué (un píxel en una cámara calibrada) y aprueba una vez por acción.
///
/// Calibrar una cámara: la pinza va sola a varios puntos (cada uno con un clic de la persona en «Move») y la
/// persona marca en la imagen dónde se ve la punta; con eso se sabe dónde está la cámara (ver CameraCalibration).
extension UseLiveRobot {
    /// Velocidad de las articulaciones al planificar (rad/s): por debajo del límite del puente (40°/s).
    static let armSpeed = 0.55
    /// Por debajo de este porcentaje de su recorrido la pinza se cerró del todo: no agarró nada.
    static let emptyGrip = 4.0

    /// Cuánto está abierta la pinza (la articulación `joint`), de 0 a 100 %, sea cual sea su escala en LeRobot.
    private func gripperPercent(_ v: Double, joint: String) -> Double {
        switch lerobot.session?.units[joint] {
        case "±100": (v + 100) / 2
        case "deg": limits[joint].map { r in r.upperBound > r.lowerBound ? (v - r.lowerBound) / (r.upperBound - r.lowerBound) * 100 : 0 } ?? v
        default: v
        }
    }

    /// Cuántos puntos se marcan al calibrar.
    static let calibrationCount = 8

    // MARK: - Calibración de la cámara

    /// La calibración guardada de una cámara (por su nombre), si hay.
    func calibration(_ cameraName: String) -> CameraFit? { device?.cameraCalibrations?[cameraName] }

    /// Empieza a calibrar: los puntos salen del espacio de trabajo de este brazo (su alcance, hacia dónde mira),
    /// así sirven para un brazo chico o uno grande.
    func startCalibration(_ cameraName: String) async {
        calibrating = cameraName
        calibrationPairs = []
        armError = nil
        syncLimits()
        calibrationTargets = (try? await twin.workspacePoints(Self.calibrationCount)) ?? []
        if calibrationTargets.isEmpty { armError = "Couldn't work out where this arm reaches (is its 3D model loaded?)." }
    }

    func cancelCalibration() {
        calibrating = nil
        calibrationPairs = []
    }

    /// Lleva la pinza (cerrada) al punto `index` de la calibración. El clic en «Move» es la aprobación.
    func moveToCalibrationPoint(_ index: Int) async {
        guard calibrationTargets.indices.contains(index) else { return }
        _ = await runSkill(["type": "reach", "point": calibrationTargets[index], "close": true], busy: "Moving to point \(index + 1)…")
    }

    /// La persona marcó dónde ve la punta (0…1): se junta con dónde está según la cinemática.
    func markCalibration(x: Double, y: Double) async {
        guard calibrating != nil else { return }
        mirror(joints)
        try? await Task.sleep(for: .milliseconds(150))   // que el gemelo copie la pose actual
        guard let tip = try? await twin.tip() else { armError = "The 3D model isn't ready."; return }
        calibrationPairs.append(.init(point: tip, pixel: [x, y]))
    }

    func undoCalibrationPoint() { if !calibrationPairs.isEmpty { calibrationPairs.removeLast() } }

    /// El ajuste con los puntos marcados hasta ahora (nil con menos de 6).
    var calibrationFit: CameraFit? {
        CameraCalibration.solve(calibrationPairs).map { CameraFit(matrix: $0.matrix, errorPx: $0.error * 640, points: calibrationPairs.count) }
    }

    // MARK: - Habilidades

    /// Pasa los límites de la calibración del robot al gemelo (en sus unidades, con JointUnits).
    func syncLimits() {
        var out: [String: [Double]] = [:]
        for (j, r) in limits {
            if let lo = toTwin(j, r.lowerBound), let hi = toTwin(j, r.upperBound) { out[j] = [min(lo, hi), max(lo, hi)] }
        }
        twin.setLimits(out)
    }

    /// Planifica en el gemelo y, si se alcanza, el robot hace la trayectoria entera. Devuelve cómo salió.
    func runSkill(_ spec: [String: Any], busy: String) async -> [String: Any] {
        guard isReady else { return ["done": false, "message": "The robot isn't live."] }
        armBusy = busy
        armError = nil
        defer { armBusy = nil }
        syncLimits()
        mirror(joints)
        try? await Task.sleep(for: .milliseconds(150))
        let names = RealAgentTools.joints
        let plan: [String: Any]
        do { plan = try await twin.planSkill(spec, names: names, speed: Self.armSpeed) } catch {
            armError = error.localizedDescription
            return ["done": false, "message": error.localizedDescription]
        }
        guard plan["ok"] as? Bool == true, let rows = plan["rows"] as? [[NSNumber]] else {
            armError = plan["message"] as? String
            return ["done": false, "reason": plan["reason"] ?? "no_plan", "message": plan["message"] ?? "Couldn't plan the move."]
        }
        // Posiciones del modelo → unidades de LeRobot de cada articulación.
        let points = rows.map { row -> [Double] in
            [row[0].doubleValue] + names.enumerated().map { i, j in
                let v = row[i + 1].doubleValue
                return fromTwin(j, v) ?? joints[j] ?? 0
            }
        }
        let seconds = (plan["seconds"] as? NSNumber)?.doubleValue ?? 5
        do { try await lerobot.liveTrajectory(points, speed: 1) } catch {
            armError = error.localizedDescription
            return ["done": false, "message": error.localizedDescription]
        }
        await settle(timeout: seconds + 6, waitPlayback: true)
        var out: [String: Any] = ["done": true, "seconds": seconds, "reach_error_cm": plan["reach_error_cm"] ?? 0]
        for key in ["object_width_cm", "gripper_max_opening_cm", "yaw_error_deg", "warning"] { if let v = plan[key] { out[key] = v } }
        // Lo que siente la pinza (sea cual sea su articulación): si se mandó cerrar y quedó abierta, hay algo adentro.
        if spec["type"] as? String != "reach", let gj = (plan["gripper"] as? [String: Any])?["joint"] as? String {
            let g = joints[gj] ?? 0
            out["gripper_percent"] = Int(gripperPercent(g, joint: gj).rounded())
            let closing = gripperPercent(targets[gj] ?? 100, joint: gj) < 10
            out["holding"] = closing && gripperPercent(g, joint: gj) > Self.emptyGrip
        }
        return out
    }

    /// De un píxel de una foto de la IA (con su tamaño) al punto de la mesa, con la calibración de esa cámara.
    func tablePoint(camera: String, x: Double, y: Double, height: Double) -> Result<[Double], ArmProblem> {
        guard let fit = calibration(camera) else { return .failure(.notCalibrated(camera)) }
        guard let size = lookSizes[camera] else { return .failure(.noPicture(camera)) }
        guard let p = CameraCalibration.point(fit.matrix, pixel: [x / Double(size.width), y / Double(size.height)], height: height) else {
            return .failure(.offTable)
        }
        return .success(p)
    }

    /// Los dos puntos donde van los dedos (píxeles de una foto) → centro del agarre, dirección de cierre y ancho.
    func pickTarget(camera: String, input: [String: Any]) -> Result<(point: [Double], yaw: [Double], width: Double), ArmProblem> {
        let n = { (k: String) in (input[k] as? NSNumber)?.doubleValue ?? 0 }
        let height = ((input["height_cm"] as? NSNumber)?.doubleValue ?? 2.5) / 100
        // Los dedos se señalan sobre el borde de arriba del objeto: el plano a su altura.
        let a = tablePoint(camera: camera, x: n("finger_a_x"), y: n("finger_a_y"), height: height)
        let b = tablePoint(camera: camera, x: n("finger_b_x"), y: n("finger_b_y"), height: height)
        switch (a, b) {
        case (.failure(let p), _), (_, .failure(let p)): return .failure(p)
        case (.success(let pa), .success(let pb)):
            let mid = zip(pa, pb).map { ($0 + $1) / 2 }
            let yaw = [pb[0] - pa[0], pb[1] - pa[1]]
            return .success((mid, yaw, hypot(yaw[0], yaw[1])))
        }
    }

    enum ArmProblem: Error {
        case notCalibrated(String), noPicture(String), offTable

        var message: String {
            switch self {
            case .notCalibrated(let c): "The camera \"\(c)\" isn't calibrated. Ask the user to calibrate it in the Arm tab (it takes a minute)."
            case .noPicture(let c): "Look through \"\(c)\" first (look), then point in that picture."
            case .offTable: "That pixel doesn't look at the table."
            }
        }
    }
}
