import SwiftUI

/// Una tarea, tal como se lista bajo su robot.
struct SidebarTask: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let phase: TaskPhase
}

/// Barra lateral: mis robots para simular y mis robots físicos (con sus tareas debajo, como archivos de un
/// proyecto). Empieza vacía; cada sección tiene su +. La fila elegida apenas se marca (≈6 %), como WhatsApp.
struct SidebarList: View {
    let robots: [Robot]
    let selectedID: String?
    let devices: [Device]
    let connectedPorts: [String]
    let selectedDeviceID: String?
    let tasks: [String: [SidebarTask]]
    let selectedTaskID: UUID?
    let onSelect: (Robot) -> Void
    let onSelectDevice: (Device) -> Void
    let onAdd: () -> Void
    let onConnect: () -> Void
    let onRemove: (Robot) -> Void
    let onRemoveDevice: (Device) -> Void
    let onReveal: (Robot) -> Void
    let onSelectTask: (Device, UUID) -> Void
    let onNewTask: (Device) -> Void
    let onRemoveTask: (UUID) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        // Encabezado y filas comparten los mismos márgenes: la fila empieza donde empieza «Robots»
        // y termina donde termina el +.
        List {
            SidebarHeader(title: "Simulation", help: "Open simulator", collapsed: isCollapsed("sim"), onToggle: { toggle("sim") }, onAdd: onAdd)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            if !isCollapsed("sim") { ForEach(robots) { robot in
                SidebarRow(icon: .robot, title: robot.name, subtitle: origin(robot), selected: robot.id == selectedID) { onSelect(robot) }
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("Show in Finder") { onReveal(robot) }
                        Divider()
                        Button("Remove from list", role: .destructive) { onRemove(robot) }
                    }
            } }

            SidebarHeader(title: "Connected robots", help: "Connect external robot", collapsed: isCollapsed("devices"), onToggle: { toggle("devices") }, onAdd: onConnect)
                .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .selectionDisabled()
            if !isCollapsed("devices") { ForEach(devices) { device in
                SidebarRow(icon: .link, title: device.name.isEmpty ? (device.guess ?? "SO-101") : device.name,
                           subtitle: !connectedPorts.contains(device.id) ? "Unplugged"
                                     : device.leaderPort == nil ? "Plugged in" : "Plugged in · with leader",
                           selected: device.id == selectedDeviceID && selectedTaskID == nil,
                           disclosure: isCollapsed(device.id) ? .closed : .open, onDisclose: { toggle(device.id) }) { onSelectDevice(device) }
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button("New task…") { onNewTask(device) }
                        Divider()
                        Button("Remove from list", role: .destructive) { onRemoveDevice(device) }
                    }
                if !isCollapsed(device.id) {
                ForEach(tasks[device.id] ?? []) { task in
                    SidebarRow(icon: icon(task.phase), title: task.title, subtitle: task.summary,
                               selected: task.id == selectedTaskID, compact: true, indent: 22) { onSelectTask(device, task.id) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                        .contextMenu { Button("Remove task", role: .destructive) { onRemoveTask(task.id) } }
                }
                SidebarRow(icon: .add, title: "New task", subtitle: nil, selected: false, compact: true, muted: true, indent: 22) { onNewTask(device) }
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            } }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.2), value: collapsed)
    }

    private func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }
    private func toggle(_ key: String) { if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) } }
}

/// Título de grupo con su botón + en bloque, alineado con los bordes de las filas.
private struct SidebarHeader: View {
    let title: String
    var help = ""
    let collapsed: Bool
    let onToggle: () -> Void
    let onAdd: (() -> Void)?
    @State private var hovering = false
    @State private var hoveringTitle = false

    var body: some View {
        HStack {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    Icon(name: .chevron, size: 10, weight: .semibold)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .opacity(hoveringTitle || collapsed ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted)
            .onHover { hoveringTitle = $0 }
            .help(collapsed ? "Show" : "Hide")
            Spacer()
            if let onAdd { Button(action: onAdd) {
                Icon(name: .add, size: 13, weight: .semibold)
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
    let subtitle: String?
    let selected: Bool
    var compact = false
    var muted = false
    /// Sangría del contenido (las tareas bajo su robot); el fondo igual ocupa todo el ancho.
    var indent: CGFloat = 0
    var disclosure: Disclosure? = nil
    var onDisclose: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon.rawValue)
                    .font(.system(size: compact ? 12 : 14))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(compact ? .callout : .body).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if let disclosure, let onDisclose {
                    Button(action: onDisclose) {
                        Icon(name: .chevron, size: 10, weight: .semibold)
                            .rotationEffect(.degrees(disclosure == .open ? 90 : 0))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .opacity(hovering || disclosure == .closed ? 1 : 0)
                    .help(disclosure == .open ? "Hide tasks" : "Show tasks")
                }
            }
            .foregroundStyle(muted ? Theme.muted : Theme.ink)
            .padding(.leading, 6 + indent)
            .padding(.trailing, 6)
            .padding(.vertical, compact ? 4 : 6)
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

enum Disclosure { case open, closed }

private func icon(_ phase: TaskPhase) -> IconName {
    switch phase {
    case .demos: .task
    case .training: .taskTraining
    case .learned: .taskLearned
    }
}

private func origin(_ robot: Robot) -> String {
    switch robot.source {
    case .bundled: "Default"
    case .library: robot.summary
    case .file: "Imported"
    }
}
