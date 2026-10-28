import Foundation
import Observation

/// Los robots físicos conectados por USB: aparecen solos al enchufarlos (se mira la lista de puertos,
/// sin abrirlos) y se prueban a pedido (abrir el puerto, buscar motores, cerrarlo). Solo lee: nunca
/// mueve el robot. Configurar y calibrar los motores se hace con LeRobot en la terminal.
@Observable
final class UseDevices {
    enum Probe: Equatable { case idle, running(Double), failed(String) }

    /// Los conectados ahora, con lo que se sabe de cada uno.
    private(set) var devices: [Device] = []
    var selectedID: String?
    private(set) var probe: Probe = .idle

    private var known: [Device] = DeviceQueries.known()
    private var watcher: Task<Void, Never>?

    var selected: Device? { devices.first { $0.id == selectedID } }
    var isProbing: Bool { if case .running = probe { true } else { false } }

    init() {
        refresh()
        #if DEBUG
        if ProcessInfo.processInfo.environment["CURIOSITY_SELECT_DEVICE"] != nil { selectedID = devices.first?.id }
        #endif
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    /// Junta los puertos conectados con lo guardado de cada uno.
    func refresh() {
        let ports = DeviceQueries.connectedPorts()
        let next = ports.map { port in known.first { $0.id == port } ?? Device(id: port, name: "") }
        if next != devices { devices = next }
        if let id = selectedID, !ports.contains(id) { selectedID = nil }
    }

    func update(_ id: String, _ change: (inout Device) -> Void) {
        var d = known.first { $0.id == id } ?? devices.first { $0.id == id } ?? Device(id: id, name: "")
        change(&d)
        known.removeAll { $0.id == id }
        known.append(d)
        DeviceQueries.save(known)
        refresh()
    }

    /// Abre el puerto, busca motores en todos los IDs (0–253) y lo cierra.
    func test(_ id: String) async {
        guard let device = devices.first(where: { $0.id == id }), !isProbing else { return }
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

    func resetProbe() { if !isProbing { probe = .idle } }
}
