import SwiftUI

/// Un robot físico conectado: qué es, cómo se le habla y la prueba de conexión.
struct DeviceScreen: View {
    let device: Device
    @Environment(UseDevices.self) private var devices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HardwareTestView(
                port: device.id,
                name: Binding(get: { device.name }, set: { v in devices.update(device.id) { $0.name = v } }),
                placeholder: device.guess ?? "SO-101",
                connected: devices.isConnected(device.id),
                testing: devices.isProbing, progress: progress, result: result, resultIsError: isError, found: device.found,
                onTest: { Task { await devices.test(device.id) } })
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(device.name.isEmpty ? (device.guess ?? "SO-101") : device.name)
        .navigationSubtitle("\(devices.isConnected(device.id) ? "Enchufado" : "Desenchufado") · \(device.portName)")
        .onChange(of: device.id) { devices.resetProbe() }
    }

    private var progress: Double { if case .running(let p) = devices.probe { p } else { 0 } }

    private var result: String? {
        if case .failed(let m) = devices.probe { return m }
        guard let at = device.probedAt else { return nil }
        let when = at.formatted(date: .omitted, time: .shortened)
        return device.found.isEmpty ? "El puerto abrió, pero no respondió ningún motor (\(when)). Revisa que el brazo tenga su fuente encendida."
                                    : "Conexión correcta: \(device.found.count) motores respondieron (\(when))."
    }

    private var isError: Bool { if case .failed = devices.probe { true } else { false } }
}
