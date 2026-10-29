import Foundation

/// La simulación como cuerpo del chat: las herramientas de AgentTools corridas sobre el motor.
extension UseSimulation: ChatBody {
    var chatTools: [[String: Any]] { AgentTools.definitions }
    var chatNotReady: String { "Wait for the robot to finish loading." }
    var chatRobotFacts: [String]? { robotFacts }

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
            return .text(AgentTools.json(out), problem: unknown.isEmpty ? nil : "No motor or doesn't exist: \(unknown.joined(separator: ", "))")

        case "look":
            let camera = (input["camera"] as? String).flatMap { model.cameras.contains($0) ? $0 : nil }
            guard let camera else { return .text("There's no camera with that name. Cameras: \(model.cameras.joined(separator: ", ")).", problem: "Unknown camera") }
            return .images([try await photo(camera)])

        case "pick", "place", "gripper":
            var spec: [String: Any] = ["type": name]
            if name == "gripper" {
                spec["open"] = input["open"] as? Bool ?? true
            } else {
                guard let camera = input["camera"] as? String, model.cameras.contains(camera) else {
                    return .text("There's no camera with that name. Cameras: \(model.cameras.joined(separator: ", ")).", problem: "Unknown camera")
                }
                spec["camera"] = camera
                spec["imageWidth"] = Self.photoWidth
                let n = { (k: String) in (input[k] as? NSNumber)?.doubleValue ?? 0 }
                if name == "pick" {
                    spec["fingers"] = [[n("finger_a_x"), n("finger_a_y")], [n("finger_b_x"), n("finger_b_y")]]
                } else {
                    spec["x"] = n("x")
                    spec["y"] = n("y")
                }
                spec["height"] = ((input["height_cm"] as? NSNumber)?.doubleValue ?? 2.5) / 100
                spec["surface"] = ((input["surface_cm"] as? NSNumber)?.doubleValue ?? 0) / 100
            }
            let outcome = try await skill(spec)
            var out = outcome
            out["joints"] = chatState(model)["joints"]
            // Una foto de la misma cámara para que vea cómo quedó (la fija de la mesa si fue solo la pinza).
            let camera = (input["camera"] as? String).flatMap { model.cameras.contains($0) ? $0 : nil } ?? model.cameras.last
            var picture: [(label: String, jpeg: Data)] = []
            if let camera { picture.append(try await photo(camera)) }
            let failed = outcome["done"] as? Bool == false
            return .report(AgentTools.json(out), photos: picture, problem: failed ? (outcome["message"] as? String ?? outcome["reason"] as? String) : nil)

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

        case "create_object":
            let (id, object) = try await designObject(input["description"] as? String ?? "")
            return .text(AgentTools.json(["id": id, "name": object.name, "size_cm": Units.centimeters(object.extent),
                                          "mass_kg": object.mass]))

        case "remove_object":
            removeObject((input["id"] as? NSNumber)?.intValue ?? -1)
            return .text("ok")

        case "reset":
            reset()
            await run(seconds: 0.3)
            return .text(AgentTools.json(chatState(model)))

        default:
            return .text("Unknown tool: \(name)", problem: "Unknown tool")
        }
    }

    private func chatState(_ model: RobotModel) -> [String: Any] {
        AgentTools.describe(state: state, model: model)
    }

    private static let photoWidth = 768

    /// Una foto de una cámara con la cuadrícula de píxeles y su tamaño, para poder señalar.
    private func photo(_ camera: String) async throws -> (label: String, jpeg: Data) {
        let size = try await cameraSize(camera)
        return ("\(camera) (\(size.width)×\(size.height) px)", try await capture(camera: camera, grid: true))
    }
}
