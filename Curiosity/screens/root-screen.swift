import SwiftUI

/// Ventana principal: mis robots (simulados y reales) a la izquierda y lo elegido a la derecha.
/// Sin nada elegido, la bienvenida: abrir el simulador o conectar un robot externo.
struct RootScreen: View {
    @Environment(UseRobots.self) private var robots
    @Environment(UseDevices.self) private var devices
    @State private var addingRobot = false
    @State private var connecting = false

    var body: some View {
        NavigationSplitView {
            SidebarList(robots: robots.robots, selectedID: devices.selectedID == nil ? robots.selectedID : nil,
                        devices: devices.devices, connectedPorts: devices.connectedPorts, selectedDeviceID: devices.selectedID,
                        onSelect: { devices.selectedID = nil; robots.selectedID = $0.id },
                        onSelectDevice: { devices.selectedID = $0.id },
                        onAdd: { addingRobot = true },
                        onConnect: { connecting = true },
                        onRemove: robots.remove,
                        onRemoveDevice: { devices.remove($0.id) },
                        onReveal: reveal)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let device = devices.selected {
                DeviceScreen(device: device)
            } else if let robot = robots.selected {
                WorkspaceScreen(robot: robot)
            } else {
                WelcomeView(onOpenSimulator: { addingRobot = true }, onConnect: { connecting = true })
            }
        }
        .sheet(isPresented: $addingRobot) { AddRobotScreen() }
        .sheet(isPresented: $connecting) { ConnectDeviceScreen() }
        // Al agregar un robot se abre él (y se cierra el dispositivo abierto), y viceversa.
        .onChange(of: robots.selectedID) { if robots.selectedID != nil, !connecting { devices.selectedID = nil } }
    }

    private func reveal(_ robot: Robot) {
        if let url = RobotQueries.fileURL(for: robot) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
