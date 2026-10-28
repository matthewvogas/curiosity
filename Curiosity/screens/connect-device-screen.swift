import SwiftUI

/// Conectar robot externo: elige el puerto USB de tu SO-101 para agregarlo a la lista.
struct ConnectDeviceScreen: View {
    @Environment(UseDevices.self) private var devices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Conectar robot externo").font(.title2.weight(.semibold))
                Text("Enchufa el SO-101 por USB y enciende su fuente. Aparece aquí en un par de segundos.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }

            VStack(spacing: Theme.Space.s) {
                if devices.available.isEmpty {
                    HStack(spacing: Theme.Space.s) {
                        ProgressView().controlSize(.small)
                        Text("Buscando robots enchufados…").font(.callout).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                }
                ForEach(devices.available, id: \.self) { port in
                    OptionCard(icon: .link, title: "SO-101",
                               detail: "USB · \(port.replacingOccurrences(of: "/dev/cu.", with: ""))") {
                        devices.add(port: port)
                        dismiss()
                    }
                }
                OptionCard(icon: .robot, title: "Otros robots", detail: "Koch, LeKiwi, OpenArm y más.",
                           badge: "Próximamente", enabled: false) {}
            }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 480)
    }
}
