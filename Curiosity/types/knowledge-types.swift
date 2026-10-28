import Foundation

/// Lo que la IA aprendió estudiando demostraciones (de esta Mac o de Hugging Face), sin entrenar nada:
/// cómo se hace la tarea por etapas, poses clave y tramos que se pueden reproducir en el robot.
struct KnowledgePackage: Identifiable, Codable, Equatable {
    struct Stage: Codable, Equatable { var name: String; var goal: String; var check: String }
    struct Pose: Codable, Equatable { var name: String; var joints: [String: Double]; var note: String }
    struct Segment: Codable, Equatable { var name: String; var episode: Int; var from: Double; var to: Double; var note: String }
    struct Picture: Codable, Equatable { var label: String; var jpeg: Data }

    var id = UUID()
    /// De dónde salió: repo_id del dataset (local/… o usuario/…).
    var source: String
    var title: String
    var createdAt = Date()
    var summary: String
    var stages: [Stage]
    var poses: [Pose]
    var segments: [Segment]
    var tips: [String]
    /// Trayectorias de las demostraciones estudiadas, en grados: episodio → [[t, articulaciones…]].
    var trajectories: [String: [[Double]]]
    /// Unas fotos de referencia (momentos clave), para que la IA compare con lo que ve.
    var pictures: [Picture]
}

/// Lo que el puente sacó de un dataset para estudiarlo.
struct StudyMaterial {
    struct Episode { var index: Int; var task: String; var duration: Double; var trajectory: [[Double]]; var events: [[String: Any]] }
    var repoID: String
    var info: [String: Any]
    var episodes: [Episode]
    var pictures: [(episode: Int, label: String, jpeg: Data)]
}
