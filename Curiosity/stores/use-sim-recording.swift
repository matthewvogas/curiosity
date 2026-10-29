import Foundation
import Observation

/// Grabar demostraciones en la simulación con el leader real: el leader mueve el robot simulado (por nombre de
/// articulación) y la cámara de la simulación y su estado van al dataset (como lerobot-record, sin el brazo real).
@Observable
final class UseSimRecording {
    private let lerobot: UseLeRobot
    private let simulation: UseSimulation
    private var pump: Task<Void, Never>?

    init(lerobot: UseLeRobot, simulation: UseSimulation) {
        self.lerobot = lerobot
        self.simulation = simulation
    }

    var session: RobotSession? { lerobot.session?.kind == "simrecord" ? lerobot.session : nil }
    var isActive: Bool { session?.active == true }

    /// Hace falta un robot abierto con articulaciones; las del leader se emparejan por nombre al empezar.
    var canRecord: Bool { !(simulation.model?.joints.isEmpty ?? true) }

    /// Las articulaciones del leader que el robot simulado no tiene (no se pueden copiar).
    var unmatched: [String] {
        guard let s = session else { return [] }
        let names = Set(simulation.model?.joints.map(\.name) ?? [])
        return s.jointNames.filter { !names.contains($0) }
    }

    func start(leader: Device, task: String, episodes: Int, seconds: Double, reset: Double) async {
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: AppPaths.datasets.path)) ?? [])
        let dataset = Naming.unique("sim_" + Naming.slug(task), taken: taken)
        if simulation.state.paused { simulation.togglePause() }
        await lerobot.simRecord(leader: leader, dataset: dataset, task: task, episodes: episodes,
                                episodeSeconds: seconds, resetSeconds: reset)
        pump?.cancel()
        pump = Task { await loop() }
    }

    func next() { lerobot.next() }
    func redo() { lerobot.redo() }
    func stop() { lerobot.stop() }

    /// Mientras graba: el robot simulado sigue al leader y cada cuadro de su cámara va al puente.
    private func loop() async {
        try? await Task.sleep(for: .milliseconds(300))
        let camera = simulation.model?.cameras.first
        while !Task.isCancelled, let s = session, s.active || s.phase == "starting" {
            let ranges = Dictionary((simulation.model?.joints ?? []).map { ($0.name, $0) }) { a, _ in a }
            for (j, v) in s.joints {
                guard let info = ranges[j],
                      let q = JointUnits.toModel(v, unit: s.units[j] ?? "deg", lower: info.lower, upper: info.upper) else { continue }
                simulation.setTarget(j, q)
            }
            if s.phase == "recording", let jpeg = try? await simulation.capture(camera: camera) {
                // El estado en las unidades del leader; una articulación que el modelo no tiene queda en 0.
                let positions = Dictionary(simulation.state.joints.map { ($0.name, $0.q) }) { a, _ in a }
                let state = Dictionary(uniqueKeysWithValues: s.jointNames.map { j -> (String, Double) in
                    guard let q = positions[j], let info = ranges[j],
                          let v = JointUnits.fromModel(q, unit: s.units[j] ?? "deg", lower: info.lower, upper: info.upper) else { return (j, 0) }
                    return (j, v)
                })
                await lerobot.simFrame(jpeg: jpeg, state: state)
            } else {
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }
}
