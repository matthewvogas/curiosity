import AVFoundation

/// Permisos del sistema que necesita el robot real. El puente de LeRobot usa la cámara a nombre de la app,
/// así que el permiso se pide aquí, antes de abrirla.
enum PermissionQueries {
    /// true si la app puede usar la cámara; la primera vez macOS le pregunta a la persona.
    static func camera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    static let cameraSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}
