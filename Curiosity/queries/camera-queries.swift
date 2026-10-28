import AVFoundation

/// Las cámaras conectadas, en el orden en que OpenCV las numera en macOS (por uniqueID), igual que el
/// puente. Se leen desde la app porque ve al instante las que se enchufan después.
enum CameraQueries {
    static func list() -> [CameraInfo] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                       mediaType: .video, position: .unspecified)
        return session.devices.sorted { $0.uniqueID < $1.uniqueID }
            .enumerated().map { CameraInfo(index: $0.offset, name: $0.element.localizedName,
                                           external: $0.element.deviceType == .external && !$0.element.isContinuityCamera) }
    }
}
