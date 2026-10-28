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
        List {
            Section {
                ForEach(robots) { robot in
                    RobotRow(robot: robot, selected: robot.id == selectedID) { onSelect(robot) }
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Mostrar en Finder") { onReveal(robot) }
                            if robot.source == .file {
                                Divider()
                                Button("Quitar de la biblioteca", role: .destructive) { onRemove(robot) }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Robots")
                    Spacer()
                    Button(action: onAdd) { Icon(name: .add, size: 12, weight: .semibold) }
                        .buttonStyle(.borderless)
                        .help("Agregar robot")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }
}

private struct RobotRow: View {
    let robot: Robot
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Icon(name: selected ? .robotFill : .robot, size: 15)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(robot.name).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(robot.source == .bundled ? "Incluido" : "Importado")
                        .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 7)
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
