import Foundation

/// El puente con LeRobot (resources/bridge/curiosity_bridge.py), corriendo con el Python donde está
/// instalado LeRobot. Se le habla por líneas JSON: cada orden tiene su respuesta y, mientras algo corre
/// con el robot, el puente manda avisos (`event`). Esta clase no guarda estado de la app: solo el proceso.
final class BridgeQueries {
    struct BridgeError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Una respuesta o un aviso del puente, tal como llega.
    struct Message: @unchecked Sendable { let json: [String: Any] }

    var onEvent: ([String: Any]) -> Void = { _ in }
    var onExit: (String) -> Void = { _ in }

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Message, Error>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var stderrTail: [String] = []

    var isRunning: Bool { process?.isRunning == true }

    /// Arranca el puente y espera a que LeRobot termine de cargar (unos segundos).
    func start(python: String, hubToken: String?) async throws {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw BridgeError(message: python.isEmpty
                ? "Couldn't find LeRobot on this Mac. Install it and set its Python in Settings › Connected robots."
                : "Can't find LeRobot's Python at \(python). Change it in Settings.")
        }
        guard let script = Bundle.main.url(forResource: "curiosity_bridge", withExtension: "py", subdirectory: "bridge") else {
            throw BridgeError(message: "The LeRobot bridge is missing from the app.")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", script.path]
        p.currentDirectoryURL = AppPaths.root
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONUNBUFFERED"] = "1"
        if let hubToken, !hubToken.isEmpty { env["HF_TOKEN"] = hubToken }
        p.environment = env

        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.keepStderr(text) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        try p.run()
        process = p
        input = inp.fileHandleForWriting
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in ready = c }
    }

    func stop() {
        input?.closeFile()   // el puente detiene lo que esté corriendo y sale
        input = nil
    }

    /// Manda una orden y espera su respuesta. Lanza el error que explique el puente.
    @discardableResult
    func request(_ cmd: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        guard isRunning, let input else { throw BridgeError(message: "The LeRobot bridge isn't running.") }
        let id = nextID
        nextID += 1
        var msg = args
        msg["id"] = id
        msg["cmd"] = cmd
        var line = try JSONSerialization.data(withJSONObject: msg)
        line.append(0x0A)
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Message, Error>) in
            waiting[id] = c
            input.write(line)
        }
        if reply.json["ok"] as? Bool == true { return reply.json }
        throw BridgeError(message: reply.json["error"] as? String ?? "LeRobot failed without saying why.")
    }

    // MARK: - Interno

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = json["id"] as? Int, let c = waiting.removeValue(forKey: id) {
                c.resume(returning: Message(json: json))
            } else if json["event"] as? String == "ready" {
                ready?.resume()
                ready = nil
            } else {
                onEvent(json)
            }
        }
    }

    private func keepStderr(_ text: String) {
        stderrTail.append(contentsOf: text.split(separator: "\n").map(String.init))
        if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
    }

    private func terminated() {
        let reason = stderrTail.last { $0.contains("Error") } ?? "The LeRobot bridge closed."
        let error = BridgeError(message: reason)
        ready?.resume(throwing: error)
        ready = nil
        for c in waiting.values { c.resume(throwing: error) }
        waiting.removeAll()
        process = nil
        input = nil
        onExit(reason)
    }
}
