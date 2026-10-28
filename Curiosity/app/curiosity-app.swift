import SwiftUI

/// Curiosity: un simulador de robots con IA. Cargas cualquier robot, conectas un modelo de IA y le
/// pides tareas en tus palabras.
///
/// Capas (de abajo hacia arriba):
///  · queries/     hablan con el disco, el Llavero, la API de Claude y el motor 3D. Sin estado.
///  · stores/      orquestan las queries y guardan carga, error y datos (los «hooks» de la app).
///  · screens/     juntan stores y componentes; son lo único que lee los stores.
///  · components/  solo dibujan; todo les llega por props.
///  · utils/ y types/: lógica pura (unidades, herramientas de la IA, tema) y tipos de datos.
@main
struct CuriosityApp: App {
    @State private var settings: UseSettings
    @State private var robots: UseRobots
    @State private var simulation: UseSimulation
    @State private var chat: UseChat
    @State private var library: UseLibrary
    @State private var devices = UseDevices()
    @State private var lerobot: UseLeRobot
    @State private var datasets: UseDatasets
    @State private var training: UseTraining

    init() {
        let settings = UseSettings()
        let simulation = UseSimulation()
        _settings = State(initialValue: settings)
        let lerobot = UseLeRobot(settings: settings)
        _lerobot = State(initialValue: lerobot)
        _datasets = State(initialValue: UseDatasets(lerobot: lerobot, settings: settings))
        _training = State(initialValue: UseTraining(settings: settings))
        let robots = UseRobots()
        _robots = State(initialValue: robots)
        _library = State(initialValue: UseLibrary(robots: robots))
        _simulation = State(initialValue: simulation)
        _chat = State(initialValue: UseChat(settings: settings, simulation: simulation))
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        // CURIOSITY_ADD_LIBRARY=<id del catálogo>: descarga y abre ese robot (para probar sin clics).
        if let id = ProcessInfo.processInfo.environment["CURIOSITY_ADD_LIBRARY"],
           let robot = _library.wrappedValue.catalog?.robots.first(where: { $0.id == id }) {
            let library = _library.wrappedValue
            Task { await library.add(robot) }
        }
        #endif
    }

    var body: some Scene {
        Window("Curiosity", id: "main") {
            RootScreen()
                .environment(settings)
                .environment(robots)
                .environment(simulation)
                .environment(chat)
                .environment(library)
                .environment(devices)
                .environment(lerobot)
                .environment(datasets)
                .environment(training)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsScreen()
                .environment(settings)
        }
    }
}
