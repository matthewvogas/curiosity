import Foundation
import Darwin

/// Entrenamientos con `lerobot-train`: lanzarlos en segundo plano (siguen aunque se cierre la app),
/// leer su avance del registro y detenerlos. La lista se guarda en training/jobs.json.
enum TrainQueries {
    private static var jobsFile: URL { AppPaths.training.appendingPathComponent("jobs.json") }

    static func jobs() -> [TrainJob] {
        guard let data = try? Data(contentsOf: jobsFile) else { return [] }
        return (try? JSONDecoder().decode([TrainJob].self, from: data)) ?? []
    }

    static func save(_ jobs: [TrainJob]) {
        try? JSONEncoder().encode(jobs).write(to: jobsFile, options: .atomic)
    }

    /// Los argumentos de `lerobot-train` para un entrenamiento.
    static func arguments(dataset: String, datasetRoot: String?, policy: PolicyOption, steps: Int, batchSize: Int,
                          outputDir: String, name: String) -> [String] {
        var args = [
            "--dataset.repo_id=\(dataset)",
            "--output_dir=\(outputDir)",
            "--job_name=\(name)",
            "--policy.device=mps",
            "--policy.push_to_hub=false",
            "--steps=\(steps)",
            "--batch_size=\(batchSize)",
            "--save_freq=\(steps > 5000 ? 5000 : steps)",
            "--log_freq=200",
        ]
        if let datasetRoot { args.append("--dataset.root=\(datasetRoot)") }
        args.append(policy.basePath.map { "--policy.path=\($0)" } ?? "--policy.type=\(policy.id)")
        return args
    }

    /// Lanza el entrenamiento en su propia sesión (no muere con la app) y mantiene la Mac despierta.
    static func launch(python: String, args: [String], log: URL, hubToken: String?) throws -> Int32 {
        let quoted = ([python, "-m", "lerobot.scripts.lerobot_train"] + args).map(shellQuote).joined(separator: " ")
        let header = "$ lerobot-train " + args.joined(separator: " ") + "\n"
        try header.write(to: log, atomically: true, encoding: .utf8)
        let script = "\(quoted) >> \(shellQuote(log.path)) 2>&1 & pid=$!; caffeinate -i -w $pid >/dev/null 2>&1 & echo $pid"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        if let hubToken, !hubToken.isEmpty { env["HF_TOKEN"] = hubToken }
        p.environment = env
        p.currentDirectoryURL = AppPaths.root
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "Curiosity", code: 5, userInfo: [NSLocalizedDescriptionKey: "No se pudo lanzar el entrenamiento."])
        }
        return pid
    }

    static func isAlive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    /// Como Ctrl+C: lo guardado en los checkpoints se conserva.
    static func stop(_ pid: Int32) { kill(pid, SIGINT) }

    /// Otro entrenamiento de LeRobot corriendo en esta Mac (de la app o de la terminal).
    static func anyRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "lerobot_train|lerobot-train"]
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Avance según la barra y las líneas de pérdida de lerobot-train.
    static func progress(_ job: TrainJob) -> TrainProgress {
        var out = TrainProgress()
        out.running = isAlive(job.pid)
        out.hasModel = FileManager.default.fileExists(atPath: job.modelPath + "/config.json")
        guard let text = tail(URL(fileURLWithPath: job.log)) else { return out }
        if let bar = text.matches(of: /(\d+)\/(\d+) \[([\d:]+)<([\d:?]+)/).last {
            out.step = Int(bar.output.1) ?? 0
            out.total = Int(bar.output.2)
            out.elapsed = String(bar.output.3)
            out.remaining = String(bar.output.4)
        }
        if let loss = text.matches(of: /\bloss:([\d.]+)/).last { out.loss = Double(loss.output.1) }
        out.finished = text.contains("End of training")
        if let error = text.matches(of: /(?m)^\w*Error: .+$/).last { out.error = String(error.output) }
        return out
    }

    private static func tail(_ url: URL, size: Int = 200_000) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(size) ? end - UInt64(size) : 0)
        return String(data: h.readDataToEndOfFile(), encoding: .utf8)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
