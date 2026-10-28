import Foundation
import WebKit

/// Puente con el motor de simulación (resources/studio/engine.js, dentro de un WKWebView).
/// Manda órdenes con `window.studio.*` y entrega crudos los mensajes que el motor publica.
final class SimulationQueries: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private var pending: [String] = []
    private var ready = false

    /// Cada mensaje del motor (ready, loading, model, state, log, error), sin transformar.
    var onMessage: ([String: Any]) -> Void = { _ in }

    /// URL de la página del motor dentro de la app.
    static let engineURL = URL(string: "curiosity://local/app/studio/index.html")!

    static func modelURL(for robot: Robot) -> String {
        switch robot.source {
        case .bundled: "curiosity://local/app/\(robot.urdfPath)"
        case .file: "curiosity://local/fs" + (robot.urdfPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? robot.urdfPath)
        }
    }

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        ready = false
    }

    // MARK: - Órdenes al motor

    func load(url: String, profile: [String: Any]) { send("studio.load", ["url": url, "profile": profile]) }
    func setTarget(_ joint: String, _ value: Double) { send("studio.setTarget", joint, value) }
    func setTargets(_ q: [String: Double], snap: Bool = false) { send("studio.setTargets", q, snap) }
    func setGains(_ joint: String, kp: Double?, kd: Double?, fmax: Double?) {
        var gains: [String: Double] = [:]
        if let kp { gains["kp"] = kp }
        if let kd { gains["kd"] = kd }
        if let fmax { gains["fmax"] = fmax }
        send("studio.setGains", joint, gains)
    }
    func setPhysics(_ p: PhysicsSettings) {
        send("studio.setPhysics", ["gravity": p.gravity, "friction": p.friction, "restitution": p.restitution, "selfCollision": p.selfCollision])
    }
    func pause(_ on: Bool) { send("studio.pause", on) }
    func step(_ n: Int = 1) { send("studio.step", n) }
    func reset() { send("studio.reset", true) }
    func setSpeed(_ x: Double) { send("studio.setSpeed", x) }
    func view(_ name: String) { send("studio.view", name) }
    func showCamera(_ name: String?) { send("studio.showCamera", name ?? NSNull()) }
    func removeObject(_ id: Int) { send("studio.removeObject", id) }

    func addObject(_ spec: [String: Any]) async throws -> Int {
        let id = try await evaluate("return studio.addObject(spec)", ["spec": spec])
        return (id as? NSNumber)?.intValue ?? 0
    }

    /// Imagen JPEG de la vista principal o de una cámara montada.
    func capture(camera: String?) async throws -> Data {
        let value = try await evaluate("return studio.capture(camera)", ["camera": camera ?? NSNull()])
        guard let url = value as? String, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
            throw NSError(domain: "Curiosity", code: 1, userInfo: [NSLocalizedDescriptionKey: "No se pudo capturar la imagen."])
        }
        return data
    }

    // MARK: - Mensajes del motor

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "ready" {
            ready = true
            for js in pending { webView?.evaluateJavaScript(js) }
            pending.removeAll()
        }
        onMessage(body)
    }

    // MARK: - Interno

    private func send(_ function: String, _ args: Any...) {
        let json = args.map { arg -> String in
            if let data = try? JSONSerialization.data(withJSONObject: [arg], options: [.fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) { return String(text.dropFirst().dropLast()) }
            return "null"
        }
        let js = "\(function)(\(json.joined(separator: ",")))"
        if ready { webView?.evaluateJavaScript(js) } else { pending.append(js) }
    }

    private func evaluate(_ body: String, _ arguments: [String: Any]) async throws -> Any? {
        guard let webView, ready else {
            throw NSError(domain: "Curiosity", code: 2, userInfo: [NSLocalizedDescriptionKey: "La simulación todavía no está lista."])
        }
        return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }
}

/// Sirve los archivos del motor y de los robots al WKWebView (esquema curiosity://).
///  · curiosity://local/app/<ruta> → recursos de la app
///  · curiosity://local/fs/<ruta absoluta> → archivos del disco (URDF y mallas importados)
final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "curiosity"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path(percentEncoded: false)
        let file: URL?
        if path.hasPrefix("/app/") {
            file = Bundle.main.resourceURL?.appendingPathComponent(String(path.dropFirst(5)))
        } else if path.hasPrefix("/fs/") {
            file = URL(fileURLWithPath: String(path.dropFirst(3)))
        } else { file = nil }

        guard let file, let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
            task.didFinish()
            return
        }
        let headers = ["Content-Type": Self.mimeType(file.pathExtension), "Access-Control-Allow-Origin": "*"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": "text/html"
        case "js", "mjs": "text/javascript"
        case "json": "application/json"
        case "urdf", "xml", "dae": "application/xml"
        case "wasm": "application/wasm"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        default: "application/octet-stream"
        }
    }
}
