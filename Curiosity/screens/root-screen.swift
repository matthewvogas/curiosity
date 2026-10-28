import SwiftUI

/// Ventana principal: mis robots (simulados y reales) a la izquierda y lo elegido a la derecha.
/// Sin nada elegido, la bienvenida: abrir el simulador o conectar un robot externo.
struct RootScreen: View {
    @Environment(UseRobots.self) private var robots
    @Environment(UseDevices.self) private var devices
    @Environment(UseTasks.self) private var tasks
    @Environment(UseDatasets.self) private var datasets
    @Environment(UseTraining.self) private var training
    @Environment(UseLeRobot.self) private var lerobot
    @State private var addingRobot = false
    @State private var connecting = false

    var body: some View {
        NavigationSplitView {
            SidebarList(robots: robots.robots, selectedID: devices.selectedID == nil ? robots.selectedID : nil,
                        devices: devices.devices, connectedPorts: devices.connectedPorts, selectedDeviceID: devices.selectedID,
                        tasks: sidebarTasks, selectedTaskID: devices.selectedID == nil ? nil : tasks.selectedID,
                        onSelect: { devices.selectedID = nil; robots.selectedID = $0.id },
                        onSelectDevice: { devices.selectedID = $0.id; tasks.selectedID = nil },
                        onAdd: { addingRobot = true },
                        onConnect: { connecting = true },
                        onRemove: robots.remove,
                        onRemoveDevice: { devices.remove($0.id) },
                        onReveal: reveal,
                        onSelectTask: { device, id in devices.selectedID = device.id; tasks.selectedID = id },
                        onNewTask: { tasks.composingFor = $0.id },
                        onRemoveTask: tasks.remove)
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
        .sheet(isPresented: Binding(get: { tasks.composingFor != nil }, set: { if !$0 { tasks.composingFor = nil } })) {
            TaskEmptyState(onCreate: { title in
                if let id = tasks.composingFor { tasks.add(title: title, deviceID: id); devices.selectedID = id }
                tasks.composingFor = nil
            }, onCancel: { tasks.composingFor = nil })
            .frame(width: 700, height: 440)
        }
        // Las tareas muestran cuántas demostraciones llevan: hacen falta los datasets (vía LeRobot).
        .task(id: devices.devices.isEmpty) {
            guard !devices.devices.isEmpty else { return }
            await lerobot.start()
            await datasets.load()
        }
        // Al agregar un robot se abre él (y se cierra el dispositivo abierto), y viceversa.
        .onChange(of: robots.selectedID) { if robots.selectedID != nil, !connecting { devices.selectedID = nil } }
    }

    private var sidebarTasks: [String: [SidebarTask]] {
        Dictionary(grouping: devices.devices.flatMap { tasks.tasks(for: $0.id) }, by: \.deviceID).mapValues { list in
            list.map { t in
                let s = TaskStatus.of(t, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
                return SidebarTask(id: t.id, title: t.title, summary: s.summary(t), phase: s.phase)
            }
        }
    }

    private func reveal(_ robot: Robot) {
        if let url = RobotQueries.fileURL(for: robot) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}
