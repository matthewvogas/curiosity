import Foundation
import Observation

/// Mis robots físicos (por ahora, el SO-101 por USB). Se agregan a mano desde «Conectar robot externo»;
/// la app solo mira qué puertos hay enchufados (sin abrirlos) y abre uno únicamente al probarlo.
/// Solo lee: nunca mueve el robot. Configurar y calibrar los motores se hace con LeRobot en la terminal.
@Observable
final class UseDevices {
    enum Probe: Equatable { case idle, running(Double), failed(String) }

    /// Los que agregué (estén o no enchufados ahora).
    private(set) var devices: [Device] = DeviceQueries.known()
    /// Puertos USB enchufados ahora.
    private(set) var connectedPorts: [String] = []
    var selectedID: String? = UserDefaults.standard.string(forKey: "devices.selected") {
        didSet { UserDefaults.standard.set(selectedID, forKey: "devices.selected") }
    }
    private(set) var probe: Probe = .idle

    private var watcher: Task<Void, Never>?

    var selected: Device? { devices.first { $0.id == selectedID } }
    var isProbing: Bool { if case .running = probe { true } else { false } }
    /// Enchufados que todavía no son parte de ningún robot (ni follower ni leader).
    var available: [String] {
        connectedPorts.filter { port in !devices.contains { $0.id == port || $0.leaderPort == port } }
    }

    func isConnected(_ id: String) -> Bool { connectedPorts.contains(id) }

    init() {
        refresh()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func refresh() {
        let ports = DeviceQueries.connectedPorts()
        if ports != connectedPorts { connectedPorts = ports }
    }

    /// Agrega un SO-101: el follower (el que trabaja) y, si hay, su leader (el que mueves con la mano).
    func add(follower: String, leader: String?) {
        devices.removeAll { $0.id == follower || $0.id == leader }
        devices.append(Device(id: follower, name: "", leaderPort: leader))
        DeviceQueries.save(devices)
        selectedID = follower
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        DeviceQueries.save(devices)
        if selectedID == id { selectedID = nil }
    }

    func update(_ id: String, _ change: (inout Device) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[i])
        DeviceQueries.save(devices)
    }

    /// Abre el puerto, busca motores en todos los IDs (0–253) y lo cierra.
    func test(_ id: String) async {
        guard let device = devices.first(where: { $0.id == id }), isConnected(id), !isProbing else { return }
        probe = .running(0)
        let bus = ServoBus(path: device.id, bus: device.bus, baud: device.baud)
        do {
            try await bus.open()
            let result = await bus.scan { p in Task { @MainActor [weak self] in
                if case .running = self?.probe { self?.probe = .running(p) }
            } }
            await bus.close()
            update(id) { $0.found = result; $0.probedAt = .now }
            probe = .idle
        } catch {
            await bus.close()
            probe = .failed(error.localizedDescription)
        }
    }

}
