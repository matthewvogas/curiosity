import AVFoundation

/// Las cámaras conectadas, en el orden en que OpenCV las numera en macOS (por uniqueID), igual que el
/// puente. Se leen desde la app porque ve al instante las que se enchufan después.
///
/// Una sola búsqueda que vive toda la app: macOS la mantiene al día al enchufar y desenchufar. Crear una
/// nueva cada vez puede devolver una lista vieja, sin la cámara que se acaba de conectar.
enum CameraQueries {
    private static let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                                    mediaType: .video, position: .unspecified)

    static func list() -> [CameraInfo] {
        discovery.devices.sorted { $0.uniqueID < $1.uniqueID }
            .enumerated().map { CameraInfo(index: $0.offset, name: $0.element.localizedName,
                                           external: $0.element.deviceType == .external && !$0.element.isContinuityCamera) }
    }

    /// Llama a `onChange` (en el hilo principal) cada vez que se conecta o desconecta una cámara.
    static func observe(_ onChange: @escaping () -> Void) -> [Any] {
        let kvo = discovery.observe(\.devices) { _, _ in DispatchQueue.main.async(execute: onChange) }
        let center = NotificationCenter.default
        let tokens = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { _ in onChange() }
        }
        return [kvo] + tokens
    }
}
