import SwiftUI

/// «Robot físico»: probar que la Mac ve el robot (puerto y motores que responden).
struct HardwareScreen: View {
    let robotName: String
    @Environment(UseHardware.self) private var hardware
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var hardware = hardware
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Probar la conexión").font(.title2.weight(.semibold))
                    Text("Comprueba que la Mac ve tu \(robotName) y cuántos motores responden.").font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Listo") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], Theme.Space.xl)

            HardwareTestView(
                ports: hardware.ports, port: $hardware.profile.port, bus: $hardware.profile.bus, baud: $hardware.profile.baud,
                testing: hardware.isTesting, progress: progress, result: result, resultIsError: isError, found: hardware.found,
                onRefresh: hardware.refreshPorts,
                onTest: { Task { await hardware.test() } })
        }
        .frame(width: 620, height: 520)
        .onAppear { hardware.refreshPorts() }
    }

    private var progress: Double { if case .testing(let p) = hardware.phase { p } else { 0 } }

    private var result: String? {
        switch hardware.phase {
        case .idle, .testing: nil
        case .done: hardware.found.isEmpty ? "El puerto abrió, pero no respondió ningún motor. Revisa la fuente, el tipo y la velocidad."
                                           : "Conexión correcta: \(hardware.found.count) motores respondieron."
        case .failed(let m): m
        }
    }

    private var isError: Bool { if case .failed = hardware.phase { true } else { false } }
}
