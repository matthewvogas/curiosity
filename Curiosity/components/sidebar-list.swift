import SwiftUI

/// Barra lateral: la biblioteca de robots. La fila elegida apenas se marca (≈6 %), como WhatsApp.
struct SidebarList: View {
    let robots: [Robot]
    let selectedID: String?
    let onSelect: (Robot) -> Void
    let onAdd: () -> Void
    let onRemove: (Robot) -> Void
    let onReveal: (Robot) -> Void

    var body: some View {
        // Encabezado y filas comparten los mismos márgenes: la fila empieza donde empieza «Robots»
        // y termina donde termina el +.
        List {
            SidebarHeader(title: "Robots", onAdd: onAdd)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            ForEach(robots) { robot in
                RobotRow(robot: robot, selected: robot.id == selectedID) { onSelect(robot) }
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Mostrar en Finder") { onReveal(robot) }
                        if robot.source == .file {
                            Divider()
                            Button("Quitar de la biblioteca", role: .destructive) { onRemove(robot) }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

/// Título de grupo con su botón + en bloque, alineado con los bordes de las filas.
private struct SidebarHeader: View {
    let title: String
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.muted)
            Spacer()
            Button(action: onAdd) {
                Icon(name: .add, size: 12, weight: .semibold)
                    .frame(width: 22, height: 22, alignment: .trailing)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .onHover { hovering = $0 }
            .help("Agregar robot")
        }
        .padding(.top, Theme.Space.s)
    }
}

private struct RobotRow: View {
    let robot: Robot
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Icon(name: selected ? .robotFill : .robot, size: 14)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(robot.name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(robot.source == .bundled ? "Incluido" : "Importado")
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
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
