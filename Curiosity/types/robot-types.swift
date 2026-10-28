import Foundation

/// Un robot de la biblioteca: de dónde sale su modelo y su perfil.
struct Robot: Identifiable, Codable, Hashable {
    enum Source: String, Codable { case bundled, file }

    var id: String
    var name: String
    var summary: String
    var source: Source
    /// Ruta del URDF: relativa al bundle (incluidos) o absoluta (importados).
    var urdfPath: String
    var license: String?
    var addedAt: Date
}

/// Lo que el motor armó a partir del URDF.
struct RobotModel: Equatable {
    var name: String
    var links: [String]
    var joints: [JointInfo]
    var cameras: [String]
    var objects: [SceneObject]
    var warnings: [String]
}

struct JointInfo: Identifiable, Equatable {
    var name: String
    var type: String
    var lower: Double?
    var upper: Double?
    var effort: Double
    var kp: Double
    var kd: Double
    var fmax: Double

    var id: String { name }
}

/// Estado de una articulación en un instante (unidades SI: rad o m, N·m o N).
struct JointState: Equatable {
    var name: String
    var q: Double
    var qd: Double
    var target: Double
    var force: Double
}

struct SimulationState: Equatable {
    var time: Double = 0
    var realTimeFactor: Double = 0
    var paused = false
    var joints: [JointState] = []
    var contacts = 0
    var maxForce: Double = 0
    var objectPositions: [Int: [Double]] = [:]
}

/// Un objeto libre de la escena (metros, kg).
struct SceneObject: Identifiable, Equatable, Codable {
    var id: Int
    var shape: String          // box · sphere · cylinder
    var size: [Double]         // caja: [x, y, z] · esfera: [r] · cilindro: [r, alto]
    var mass: Double
    var color: String
    var pos: [Double]
    var yaw: Double = 0
    var fixed = false
    var name = ""
}

struct PhysicsSettings: Equatable {
    var gravity = 9.81
    var friction = 0.7
    var restitution = 0.05
    var selfCollision = false
}
