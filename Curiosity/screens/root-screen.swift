import SwiftUI
import UniformTypeIdentifiers

/// Ventana principal: biblioteca de robots a la izquierda y el espacio de trabajo del elegido.
struct RootScreen: View {
    @Environment(UseRobots.self) private var robots
    @Environment(UseDevices.self) private var devices
    @State private var addingRobot = false

    var body: some View {
        NavigationSplitView {
            SidebarList(robots: robots.robots, selectedID: devices.selectedID == nil ? robots.selectedID : nil,
                        devices: devices.devices, selectedDeviceID: devices.selectedID,
                        onSelect: { devices.selectedID = nil; robots.selectedID = $0.id },
                        onSelectDevice: { devices.selectedID = $0.id },
                        onAdd: { addingRobot = true },
                        onRemove: robots.remove,
                        onReveal: reveal)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let device = devices.selected {
                DeviceScreen(device: device)
            } else if let robot = robots.selected {
                WorkspaceScreen(robot: robot)
            } else {
                ContentUnavailableView {
                    Label("Agrega un robot", systemImage: IconName.robot.rawValue)
                } description: {
                    Text("Empieza con uno incluido o importa el URDF de cualquier robot.")
                } actions: {
                    Button("Agregar robot") { addingRobot = true }.buttonStyle(.glassProminent)
                }
            }
        }
        .sheet(isPresented: $addingRobot) { AddRobotScreen() }
    }

    private func reveal(_ robot: Robot) {
        if let url = RobotQueries.fileURL(for: robot) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
