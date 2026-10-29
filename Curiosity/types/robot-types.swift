import Foundation

/// Un robot de la biblioteca: de dónde sale su modelo y su perfil.
struct Robot: Identifiable, Codable, Hashable {
    enum Source: String, Codable { case bundled, file, library }

    var id: String
    var name: String
    var summary: String
    var source: Source
    /// Ruta del modelo (URDF o MJCF): relativa al bundle (incluidos) o absoluta (importados y de la biblioteca).
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
    var mass: Double = 0
    /// La base no está fija al suelo (robots móviles, cuadrúpedos, humanoides).
    var floating = false

    /// Las articulaciones que se controlan (las acopladas y las pasivas se mueven solas).
    var actuatedJoints: [JointInfo] { joints.filter(\.actuated) }
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
    /// Tiene motor propio.
    var actuated = true
    /// Sigue a otra articulación (pinzas de dos dedos, dedos acoplados).
    var mimic: String?

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
    /// Fuerza de contacto por pieza del robot (N).
    var linkForces: [String: Double] = [:]
    /// Profiler: milisegundos por paso de física.
    var stepMs: Double = 0
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
    /// Si está, el objeto se arma con estas piezas (una rueda, un escritorio…) en lugar de `shape`/`size`.
    var parts: [ObjectPart]?
    /// Giro completo en grados [x, y, z]; si no está, solo `yaw`.
    var euler: [Double]?

    /// Lo que mide (largo x, ancho y, alto z, en metros) en su propio marco, aproximado por sus piezas.
    var extent: [Double] {
        guard let parts, !parts.isEmpty else { return Self.halfSize(shape: shape, size: size).map { $0 * 2 } }
        var lo = [Double.infinity, .infinity, .infinity], hi = [-Double.infinity, -.infinity, -.infinity]
        for p in parts where p.pos.count == 3 {
            var half = Self.halfSize(shape: p.shape, size: p.size)
            // Una pieza girada: se toma su medida mayor en todas las direcciones (cota segura).
            if p.euler.contains(where: { $0 != 0 }) { half = Array(repeating: half.max() ?? 0, count: 3) }
            for i in 0..<3 {
                lo[i] = min(lo[i], p.pos[i] - half[i])
                hi[i] = max(hi[i], p.pos[i] + half[i])
            }
        }
        return (0..<3).map { lo[$0].isFinite ? hi[$0] - lo[$0] : 0 }
    }

    /// El color con que se ve (el de su primera pieza, si tiene).
    var displayColor: String { parts?.first?.color ?? color }

    /// Medio tamaño de una forma simple: caja [x, y, z] · esfera [r] · cilindro [r, alto] · cápsula [r, largo].
    private static func halfSize(shape: String, size: [Double]) -> [Double] {
        let a = size.first ?? 0, b = size.count > 1 ? size[1] : a
        switch shape {
        case "sphere": return [a, a, a]
        case "cylinder": return [a, a, b / 2]
        case "capsule": return [a, a, b / 2 + a]
        default: return [a / 2, b / 2, (size.count > 2 ? size[2] : a) / 2]
        }
    }
}

/// Una pieza de un objeto compuesto (metros, grados), relativa al centro del objeto.
struct ObjectPart: Equatable, Codable {
    var shape: String          // box · sphere · cylinder · capsule
    var size: [Double]
    var pos: [Double]
    var euler: [Double] = [0, 0, 0]
    var color: String

    private enum CodingKeys: String, CodingKey { case shape, size, pos, euler, color }

    init(shape: String, size: [Double], pos: [Double], euler: [Double] = [0, 0, 0], color: String) {
        self.shape = shape; self.size = size; self.pos = pos; self.euler = euler; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(String.self, forKey: .shape) ?? "box"
        size = try c.decodeIfPresent([Double].self, forKey: .size) ?? []
        pos = try c.decodeIfPresent([Double].self, forKey: .pos) ?? [0, 0, 0]
        euler = try c.decodeIfPresent([Double].self, forKey: .euler) ?? [0, 0, 0]
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#9a9a9f"
    }
}

struct PhysicsSettings: Equatable {
    var gravity = 9.81
    var friction = 0.7
    var restitution = 0.05
    var selfCollision = false
    /// Paso de tiempo (s) e iteraciones del solver.
    var timestep = 1.0 / 500
    var iterations = 8.0
    /// Ruido en el control, como MuJoCo: escala (fracción del rango) y tiempo de correlación (s).
    var noiseScale = 0.0
    var noiseRate = 0.0
}

/// Qué se dibuja en la escena (flags de render de MuJoCo).
struct RenderOptions: Equatable {
    var contacts = true
    var joints = false
    var collision = false
    var com = false
    var transparent = false
    var grid = true
    var shadows = true
}

/// Un estado guardado (posiciones de las articulaciones y de los objetos), como los keyframes de MuJoCo.
struct Keyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var json: String
    var savedAt = Date()
}
