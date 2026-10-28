import SwiftUI
import UniformTypeIdentifiers

/// Ventana principal: biblioteca de robots a la izquierda y el espacio de trabajo del elegido.
struct RootScreen: View {
    @Environment(UseRobots.self) private var robots
    @State private var addingRobot = false

    var body: some View {
        NavigationSplitView {
            SidebarList(robots: robots.robots, selectedID: robots.selectedID,
                        onSelect: { robots.selectedID = $0.id },
                        onAdd: { addingRobot = true },
                        onRemove: robots.remove,
                        onReveal: reveal)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let robot = robots.selected {
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
