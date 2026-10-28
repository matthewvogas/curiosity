import Foundation
import Observation

/// Entrenamientos con lerobot-train: lanzarlos, ver su avance y detenerlos. Siguen aunque se cierre la app.
@Observable
final class UseTraining {
    private let settings: UseSettings

    private(set) var jobs: [TrainJob] = TrainQueries.jobs()
    private(set) var progress: [String: TrainProgress] = [:]
    private(set) var message: String?
    /// El entrenamiento abierto en vivo (curva y registro); nil si no se está mirando ninguno.
    private(set) var watched: TrainWatch?
    private var poller: Task<Void, Never>?

    init(settings: UseSettings) {
        self.settings = settings
        refresh()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refresh()
            }
        }
    }

    var finished: [TrainJob] { jobs.filter { progress[$0.name]?.hasModel == true } }

    func refresh() {
        let next = Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, TrainQueries.progress($0)) })
        if next != progress { progress = next }
        if let name = watched?.name, let job = jobs.first(where: { $0.name == name }) {
            let w = TrainWatch(name: name, history: TrainQueries.history(job), log: TrainQueries.logTail(job))
            if w != watched { watched = w }
        }
    }

    /// Empieza (o deja) de mirar un entrenamiento en vivo.
    func watch(_ name: String?) {
        watched = name.map { TrainWatch(name: $0) }
        refresh()
    }

    /// Lanza un entrenamiento. `dataset` es un repo_id (local/… para los de esta Mac, usuario/… del Hub).
    func start(name: String, dataset: String, datasetRoot: String?, policy: PolicyOption, steps: Int, batchSize: Int) {
        message = nil
        guard AppPaths.isValidName(name) else { message = "The name can only have letters, numbers, - and _."; return }
        guard !jobs.contains(where: { $0.name == name }) else { message = "There's already a training called “\(name)”."; return }
        guard !TrainQueries.anyRunning() else { message = "A training is already running: two at once fight over the GPU."; return }
        let output = AppPaths.training.appendingPathComponent(name).path
        let log = AppPaths.logs.appendingPathComponent("\(name).log")
        let args = TrainQueries.arguments(dataset: dataset, datasetRoot: datasetRoot, policy: policy, steps: steps,
                                          batchSize: batchSize, outputDir: output, name: name)
        do {
            let pid = try TrainQueries.launch(python: settings.lerobotPython, args: args, log: log, hubToken: settings.hubToken)
            jobs.insert(TrainJob(name: name, dataset: dataset, datasetRoot: datasetRoot, policy: policy.id, steps: steps,
                                 batchSize: batchSize, started: .now, pid: pid, log: log.path, outputDir: output), at: 0)
            TrainQueries.save(jobs)
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func stop(_ job: TrainJob) {
        TrainQueries.stop(job.pid)
        if let i = jobs.firstIndex(where: { $0.name == job.name }) { jobs[i].stopped = .now }
        TrainQueries.save(jobs)
    }

    func remove(_ job: TrainJob) {
        jobs.removeAll { $0.name == job.name }
        TrainQueries.save(jobs)
        progress[job.name] = nil
    }
}
