import Foundation

/// En qué va una tarea: se deduce de sus demostraciones grabadas y de su entrenamiento.
enum TaskPhase { case demos, training, learned }

struct TaskStatus {
    let demos: Int
    let job: TrainJob?
    let progress: TrainProgress?

    var isTraining: Bool { progress?.running == true }
    var hasModel: Bool { progress?.hasModel == true }
    var phase: TaskPhase { isTraining ? .training : hasModel ? .learned : .demos }

    /// Lo que se ve en la barra lateral y en las tarjetas.
    func summary(_ task: TeachTask) -> String {
        if isTraining { return "Training · \(Int((progress?.fraction ?? 0) * 100)) %" }
        if hasModel { return "Learned" }
        if task.hubDataset { return "Data from Hugging Face" }
        return demos == 0 ? "No demonstrations" : "\(demos) of \(task.episodes) demonstrations"
    }

    static func of(_ task: TeachTask, datasets: [DatasetInfo], jobs: [TrainJob], progress: [String: TrainProgress]) -> TaskStatus {
        let demos = datasets.first { $0.source == (task.hubDataset ? "hub" : "local") && $0.name == task.dataset }?.episodes ?? 0
        let job = jobs.first { $0.name == task.trainName || $0.name.hasPrefix(task.trainName + "_") }
        return TaskStatus(demos: demos, job: job, progress: job.flatMap { progress[$0.name] })
    }
}
