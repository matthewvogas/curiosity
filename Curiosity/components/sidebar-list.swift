import SwiftUI

/// Barra lateral: mis robots para simular y mis robots físicos. Empieza vacía; cada sección tiene su +.
/// La fila elegida apenas se marca (≈6 %), como WhatsApp.
struct SidebarList: View {
    let robots: [Robot]
    let selectedID: String?
    let devices: [Device]
    let connectedPorts: [String]
    let selectedDeviceID: String?
    let onSelect: (Robot) -> Void
    let onSelectDevice: (Device) -> Void
    let onAdd: () -> Void
    let onConnect: () -> Void
    let onRemove: (Robot) -> Void
    let onRemoveDevice: (Device) -> Void
    let onReveal: (Robot) -> Void

    var body: some View {
        // Encabezado y filas comparten los mismos márgenes: la fila empieza donde empieza «Robots»
        // y termina donde termina el +.
        List {
            SidebarHeader(title: "Simulación", help: "Abrir simulador", onAdd: onAdd)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            ForEach(robots) { robot in
                SidebarRow(icon: .robot, title: robot.name, subtitle: origin(robot), selected: robot.id == selectedID) { onSelect(robot) }
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Mostrar en Finder") { onReveal(robot) }
                        Divider()
                        Button("Quitar de la lista", role: .destructive) { onRemove(robot) }
                    }
            }

            SidebarHeader(title: "Robots reales", help: "Conectar robot externo", onAdd: onConnect)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            ForEach(devices) { device in
                SidebarRow(icon: .link, title: device.name.isEmpty ? (device.guess ?? "SO-101") : device.name,
                           subtitle: !connectedPorts.contains(device.id) ? "Desenchufado"
                                     : device.leaderPort == nil ? "Enchufado" : "Enchufado · con leader",
                           selected: device.id == selectedDeviceID) { onSelectDevice(device) }
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu { Button("Quitar de la lista", role: .destructive) { onRemoveDevice(device) } }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// Título de grupo con su botón + en bloque, alineado con los bordes de las filas.
private struct SidebarHeader: View {
    let title: String
    var help = ""
    let onAdd: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Spacer()
            if let onAdd { Button(action: onAdd) {
                Icon(name: .add, size: 12, weight: .semibold)
                    .frame(width: 22, height: 22, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .onHover { hovering = $0 }
            .help(help) }
        }
        .padding(.top, Theme.Space.s)
    }
}

/// Una fila de la barra lateral: ícono (relleno al elegirla), título y una línea de contexto.
private struct SidebarRow: View {
    let icon: IconName
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon.rawValue)
                    .font(.system(size: 14))
                    .symbolVariant(selected ? .fill : .none)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : hovering ? Theme.hover : .clear,
                        in: .rect(cornerRadius: Theme.Radius.row))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private func origin(_ robot: Robot) -> String {
    switch robot.source {
    case .bundled: "Default"
    case .library: robot.summary
    case .file: "Importado"
    }
}
