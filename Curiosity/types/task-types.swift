import Foundation

/// Una tarea que se le enseña al robot real: sus demostraciones (un dataset) y el modelo que se entrena.
struct TeachTask: Identifiable, Codable, Equatable {
    var id = UUID()
    var deviceID: String
    /// Lo que debe hacer, en palabras («Pon el cubo rojo en el vaso»).
    var title: String
    /// Dataset propio (carpeta en datasets/) o, si `hubDataset`, un repo de Hugging Face.
    var dataset: String
    var hubDataset = false
    var createdAt = Date()

    // Opciones (valores iniciales; cada tarea los cambia)
    var episodes = 50
    var episodeSeconds = 60.0
    var resetSeconds = 10.0
    var policy = "act"
    var steps = 20_000
    var batchSize = 8
    var runSeconds = 60.0

    /// Nombre del entrenamiento de esta tarea.
    var trainName: String { "\(policy)_\(dataset.replacingOccurrences(of: "/", with: "_"))" }
    /// repo_id para LeRobot.
    var repoID: String { hubDataset ? dataset : "local/\(dataset)" }
}
