import Foundation
import Observation

/// Grabar demostraciones en la simulación con el leader real: el leader mueve el SO-101 simulado y la
/// cámara de la simulación y su estado van al dataset (como lerobot-record, sin el brazo real).
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

    /// Si el robot abierto es un SO-100/101 (tiene sus seis articulaciones).
    var canRecord: Bool {
        let names = Set(simulation.model?.joints.map(\.name) ?? [])
        return RealAgentTools.joints.allSatisfy(names.contains)
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
            for (j, deg) in s.joints {
                simulation.setTarget(j, j == "gripper" ? deg / 100 * Self.gripperRange : deg * .pi / 180)
            }
            if s.phase == "recording", let jpeg = try? await simulation.capture(camera: camera) {
                let state = Dictionary(uniqueKeysWithValues: simulation.state.joints
                    .filter { RealAgentTools.joints.contains($0.name) }
                    .map { ($0.name, $0.name == "gripper" ? $0.q / Self.gripperRange * 100 : $0.q * 180 / .pi) })
                await lerobot.simFrame(jpeg: jpeg, state: state)
            } else {
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// La pinza del SO-101 en el URDF va de 0 a 1.745 rad; LeRobot la mide de 0 a 100.
    private static let gripperRange = 1.74533
}
