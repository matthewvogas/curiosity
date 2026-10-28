import Foundation

/// Lo que se sabe del LeRobot instalado (lo dice el puente al arrancar).
struct LeRobotEnv: Equatable {
    var version: String
    var hubUser: String?
    var smolvla: Bool
}

/// Calibraciones guardadas por LeRobot: tipo (so_follower, so_leader) → nombres (mi_follower…).
struct Calibrations: Equatable {
    var robots: [String: [String]] = [:]
    var teleoperators: [String: [String]] = [:]

    var followers: [String] { robots["so_follower"] ?? robots.values.flatMap { $0 } }
    var leaders: [String] { teleoperators["so_leader"] ?? teleoperators.values.flatMap { $0 } }
}

struct CameraInfo: Identifiable, Equatable {
    var index: Int
    var name: String
    /// Enchufada por USB (no la de la Mac ni la de Continuidad): la preferida para el robot.
    var external = false
    var id: Int { index }
}

/// Un dataset de LeRobot en esta Mac (grabado aquí o descargado del Hub).
struct DatasetInfo: Identifiable, Equatable {
    var name: String          // carpeta, o <usuario>/<nombre> si vino del Hub
    var root: String
    var source: String        // local · hub
    var episodes: Int
    var frames: Int
    var fps: Double?
    var tasks: [String]
    var bytes: Int
    var cameras: [String]

    var id: String { root }
    var repoID: String { source == "hub" ? name : "local/\(name)" }
}

/// Un dataset del Hub de Hugging Face (resultado de búsqueda).
struct HubDataset: Identifiable, Equatable {
    var id: String            // usuario/nombre
    var downloads: Int
    var likes: Int
    var url: URL { URL(string: "https://huggingface.co/datasets/\(id)")! }
}

/// El estado de lo que corre con el robot: teleoperar, grabar o un modelo.
struct RobotSession: Equatable {
    var kind: String          // teleop · record · rollout
    var phase: String         // starting · running · recording · reset · saving · returning · stopping · done · error
    var active: Bool
    var error: String?
    var hz: Double = 0
    var joints: [String: Double] = [:]
    var episode = 0
    var target = 0
    var elapsed: Double = 0
    var limit: Double = 0
    /// En vivo: a dónde va cada articulación y su rango (grados; la pinza de 0 a 100).
    var targets: [String: Double] = [:]
    var limits: [String: ClosedRange<Double>] = [:]
    /// En vivo: reproduciendo un tramo de una demostración.
    var playing = false

    var remaining: Double { max(0, limit - elapsed) }
}

/// Un entrenamiento lanzado desde la app (corre aparte aunque se cierre la app).
/// Una pieza revisada antes de grabar o probar: follower, leader, poses, cámara o permiso.
struct PreflightCheck: Identifiable, Equatable {
    enum State: String { case ok, warn, fail }
    let key: String
    let state: State
    let detail: String

    var id: String { key }
    var title: String {
        switch key {
        case "follower": "Follower"
        case "leader": "Leader"
        case "pose": "Poses"
        case "camera": "Cámara"
        case "permission": "Permiso de cámara"
        case let k where k.hasPrefix("cam"): "Cámara \(Int(k.dropFirst(3)).map { $0 + 1 } ?? 2)"
        default: key
        }
    }
}

struct TrainJob: Identifiable, Codable, Equatable {
    var name: String
    var dataset: String       // repo_id (local/… o usuario/…)
    var datasetRoot: String?  // solo para los locales
    var policy: String
    var steps: Int
    var batchSize: Int
    var started: Date
    var pid: Int32
    var log: String
    var outputDir: String
    var stopped: Date?

    var id: String { name }
    var modelPath: String { outputDir + "/checkpoints/last/pretrained_model" }
}

/// El avance de un entrenamiento, leído de su registro.
struct TrainProgress: Equatable {
    var step = 0
    var total: Int?
    var elapsed: String?
    var remaining: String?
    var loss: Double?
    var finished = false
    var error: String?
    var running = false
    var hasModel = false

    var fraction: Double { total.map { $0 > 0 ? Double(step) / Double($0) : 0 } ?? 0 }
}

/// Modelos de LeRobot que se pueden entrenar desde la app.
struct PolicyOption: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    /// Se entrena partiendo de este modelo del Hub (SmolVLA).
    let basePath: String?
    let needsSmolVLA: Bool

    static let all: [PolicyOption] = [
        PolicyOption(id: "act", name: "ACT", detail: "Rápido y fiable con 50 demostraciones. El recomendado para empezar.", basePath: nil, needsSmolVLA: false),
        PolicyOption(id: "diffusion", name: "Diffusion", detail: "Movimientos más suaves; tarda más en entrenar.", basePath: nil, needsSmolVLA: false),
        PolicyOption(id: "smolvla", name: "SmolVLA", detail: "Entiende la tarea en palabras. Parte de lerobot/smolvla_base; lento en Mac.", basePath: "lerobot/smolvla_base", needsSmolVLA: true),
    ]
}
