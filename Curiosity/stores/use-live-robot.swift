import Foundation
import Observation

/// El robot real en vivo: conectarlo (se queda firme), moverlo con los controles o con la IA, y soltarlo
/// (vuelve a su pose del principio). Es también el cuerpo del chat con el robot real.
@Observable
final class UseLiveRobot {
    private let lerobot: UseLeRobot
    /// Objetivos de los deslizadores aún sin mandar (se juntan para no saturar el puente).
    private var outgoing: [String: Double] = [:]
    private var flushing = false

    init(lerobot: UseLeRobot) {
        self.lerobot = lerobot
    }

    var isLive: Bool { lerobot.session?.kind == "live" && lerobot.session?.active == true }
    var isReturning: Bool { isLive && lerobot.session?.phase == "returning" }
    var isReady: Bool { isLive && lerobot.session?.phase == "running" }
    var joints: [String: Double] { isLive ? lerobot.session?.joints ?? [:] : [:] }
    var targets: [String: Double] { isLive ? (lerobot.session?.targets ?? [:]).merging(outgoing) { $1 } : [:] }
    var limits: [String: ClosedRange<Double>] { isLive ? lerobot.session?.limits ?? [:] : [:] }
    var frame: Data? { lerobot.frame }

    func start(_ device: Device) async { await lerobot.live(device) }
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

    func home() { Task { try? await lerobot.liveHome() } }

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
            return .text(AgentTools.json(RealAgentTools.describe(joints: joints, targets: targets, limits: limits)))

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
            try await lerobot.liveTargets(batch)
            await settle(timeout: longest / 40 + 2)
            var out = RealAgentTools.describe(joints: joints, targets: targets, limits: limits)
            if !clipped.isEmpty { out["clipped_to_limits"] = clipped }
            return .text(AgentTools.json(out), problem: clipped.isEmpty ? nil : "Ajustado al rango: \(clipped.joined(separator: ", "))")

        case "look":
            return .image(try await lerobot.liveLook())

        case "go_home":
            try await lerobot.liveHome()
            await settle(timeout: 8)
            return .text(AgentTools.json(RealAgentTools.describe(joints: joints, targets: targets, limits: limits)))

        default:
            return .text("Herramienta desconocida: \(name)", problem: "Herramienta desconocida")
        }
    }
}
