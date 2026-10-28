#if DEBUG
import AppKit

/// Solo en Debug: CURIOSITY_SNAPSHOT=/ruta.png guarda una imagen de la ventana y cierra la app.
/// Sirve para revisar el diseño desde la terminal.
enum DebugSnapshot {
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CURIOSITY_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["CURIOSITY_SNAPSHOT_DELAY"] ?? "") ?? 9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // CURIOSITY_SNAPSHOT_SHEET=1: la hoja abierta encima de la ventana.
            let wantsSheet = ProcessInfo.processInfo.environment["CURIOSITY_SNAPSHOT_SHEET"] != nil
            let main = NSApp.windows.first(where: { $0.isVisible && $0.title == "Curiosity" }) ?? NSApp.windows.first(where: \.isVisible)
            let sheet = NSApp.windows.first { $0.sheetParent != nil && $0.isVisible }
            if let window = wantsSheet ? (sheet ?? main) : main {
                typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
                if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
                   let image = unsafeBitCast(sym, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path))
                }
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
