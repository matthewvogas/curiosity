import SwiftUI
import WebKit

/// El escenario 3D: el motor de simulación dentro de un WKWebView, a todo lo ancho.
/// Recibe el puente del motor; no decide nada.
struct SimStage: NSViewRepresentable {
    let engine: SimulationQueries
    /// Espacio que tapa el panel flotante a la derecha: la cámara centra el robot en lo visible.
    var rightInset: CGFloat = 0

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        config.userContentController.add(engine, name: "studio")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        engine.attach(web)
        web.load(URLRequest(url: SimulationQueries.engineURL))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        engine.attach(web)
        web.evaluateJavaScript("window.studio && studio.setInsets && studio.setInsets({ right: \(Int(rightInset)) })")
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: ()) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "studio")
    }
}
