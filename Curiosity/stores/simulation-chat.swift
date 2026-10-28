import Foundation

/// La simulación como cuerpo del chat: las herramientas de AgentTools corridas sobre el motor.
extension UseSimulation: ChatBody {
    var chatTools: [[String: Any]] { AgentTools.definitions }
    var chatNotReady: String { "Espera a que el robot termine de cargar." }

    func chatSystemPrompt(robotName: String) -> String? {
        model.map { AgentTools.systemPrompt(model: $0, robotName: robotName) }
    }

    func chatTitle(_ name: String, _ input: [String: Any]) -> String { AgentTools.title(for: name, input: input) }

    /// En la simulación no hay riesgo: nada espera aprobación.
    func chatApproval(_ name: String, _ input: [String: Any]) -> String? { nil }

    func chatRun(_ name: String, _ input: [String: Any]) async throws -> ChatToolOutput {
        guard let model else { throw NSError(domain: "Curiosity", code: 7, userInfo: [NSLocalizedDescriptionKey: chatNotReady]) }
        switch name {
        case "get_state":
            return .text(AgentTools.json(chatState(model)))

        case "move_joints":
            let types = Dictionary(uniqueKeysWithValues: model.joints.map { ($0.name, $0) })
            var unknown: [String] = []
            for t in input["targets"] as? [[String: Any]] ?? [] {
                guard let joint = t["joint"] as? String, let value = (t["value"] as? NSNumber)?.doubleValue else { continue }
                guard let info = types[joint], info.actuated else { unknown.append(joint); continue }
                var v = Units.fromDisplay(value, jointType: info.type)
                if let lo = info.lower, let hi = info.upper { v = min(hi, max(lo, v)) }
                setTarget(joint, v)
            }
            let seconds = min(5, max(0.2, (input["seconds"] as? NSNumber)?.doubleValue ?? 1.5))
            await run(seconds: seconds)
            var out = chatState(model)
            if !unknown.isEmpty { out["unknown_joints"] = unknown }
            return .text(AgentTools.json(out), problem: unknown.isEmpty ? nil : "Sin motor o no existe: \(unknown.joined(separator: ", "))")

        case "look":
            let camera = (input["camera"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .images([("", try await capture(camera: camera))])

        case "add_object":
            let size = Units.meters((input["size_cm"] as? [NSNumber] ?? []).map(\.doubleValue))
            let pos = Units.meters((input["position_cm"] as? [NSNumber] ?? []).map(\.doubleValue))
            let object = SceneObject(id: 0, shape: input["shape"] as? String ?? "box",
                                     size: size.isEmpty ? [0.03, 0.03, 0.03] : size,
                                     mass: ((input["mass_g"] as? NSNumber)?.doubleValue ?? 20) / 1000,
                                     color: input["color"] as? String ?? "#cccccc",
                                     pos: pos.count == 3 ? pos : [0.2, 0, 0.1])
            let newID = try await addObject(object)
            return .text(AgentTools.json(["id": newID]))

        case "remove_object":
            removeObject((input["id"] as? NSNumber)?.intValue ?? -1)
            return .text("ok")

        case "reset":
            reset()
            await run(seconds: 0.3)
            return .text(AgentTools.json(chatState(model)))

        default:
            return .text("Herramienta desconocida: \(name)", problem: "Herramienta desconocida")
        }
    }

    private func chatState(_ model: RobotModel) -> [String: Any] {
        AgentTools.describe(state: state, model: model, objects: objects)
    }
}
