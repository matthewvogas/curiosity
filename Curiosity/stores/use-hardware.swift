import Foundation
import Observation

/// Probar la conexión con el robot físico: abre el puerto, busca qué motores responden y lo cierra.
/// Solo lee; nunca mueve el robot. Configurar y calibrar los motores se hace con LeRobot en la terminal.
@Observable
final class UseHardware {
    enum Phase: Equatable { case idle, testing(Double), done, failed(String) }

    private(set) var robotID: String?
    private(set) var ports: [String] = []
    var profile = HardwareProfile() { didSet { save() } }
    private(set) var phase: Phase = .idle
    private(set) var found: [FoundMotor] = []

    var isTesting: Bool { if case .testing = phase { true } else { false } }

    /// Al abrir un robot: su configuración guardada o la sugerida por su perfil.
    func open(robotID: String, robotProfile: [String: Any]) {
        guard robotID != self.robotID else { return }
        self.robotID = robotID
        found = []
        phase = .idle
        if let saved = HardwareQueries.load(robotID: robotID) {
            profile = saved
        } else {
            var p = HardwareProfile()
            if let hw = robotProfile["hardware"] as? [String: Any] {
                if let bus = (hw["bus"] as? String).flatMap(BusProtocol.init(rawValue:)) { p.bus = bus; p.baud = bus.defaultBaud }
                if let baud = (hw["baud"] as? NSNumber)?.intValue { p.baud = baud }
            }
            profile = p
        }
        refreshPorts()
    }

    func refreshPorts() {
        ports = SerialPort.available()
        if profile.port == nil || !ports.contains(profile.port!) {
            // Sugerencia: el primer adaptador USB (cu.usbmodem… / cu.usbserial…).
            profile.port = ports.first { $0.contains("usb") }
        }
    }

    /// Abre el puerto, busca motores en todos los IDs (0–253) y lo cierra.
    func test() async {
        guard let path = profile.port, !isTesting else { return }
        found = []
        phase = .testing(0)
        let bus = ServoBus(path: path, bus: profile.bus, baud: profile.baud)
        do {
            try await bus.open()
            let result = await bus.scan { p in Task { @MainActor [weak self] in
                if case .testing = self?.phase { self?.phase = .testing(p) }
            } }
            await bus.close()
            found = result
            phase = .done
        } catch {
            await bus.close()
            phase = .failed(error.localizedDescription)
        }
    }

    private func save() {
        guard let robotID else { return }
        try? HardwareQueries.save(profile, robotID: robotID)
    }
}
