import Foundation

/// Mis robots físicos (Application Support/Curiosity/devices.json): nombre y la última prueba de cada
/// puerto. Que estén enchufados ahora lo dice `connectedPorts()`.
enum DeviceQueries {
    private static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Curiosity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devices.json")
    }

    static func known() -> [Device] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    static func save(_ devices: [Device]) {
        try? JSONEncoder().encode(devices).write(to: file, options: .atomic)
    }

    /// Puertos USB serie conectados ahora (solo mira /dev, no abre nada).
    static func connectedPorts() -> [String] {
        SerialPort.available().filter { $0.contains("usb") }
    }
}
