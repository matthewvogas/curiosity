import SwiftUI
import UniformTypeIdentifiers

/// Agregar un robot: uno incluido o un URDF del disco.
struct AddRobotScreen: View {
    @Environment(UseRobots.self) private var robots
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Agregar un robot").font(.title2.weight(.semibold))
                Text("Cualquier robot descrito en URDF: brazos, manos, móviles, humanoides.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(robots.robots.filter { $0.source == .bundled }) { robot in
                    OptionCard(icon: .robot, title: robot.name, detail: robot.summary, badge: "Incluido") {
                        robots.selectedID = robot.id
                        dismiss()
                    }
                }
                OptionCard(icon: .file, title: "Importar un URDF",
                           detail: "Elige el archivo .urdf; sus mallas (STL, OBJ o DAE) se leen desde su carpeta.") {
                    importing = true
                }
            }

            if let error = robots.error {
                Label(error, systemImage: IconName.warning.rawValue).font(.callout).foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 520)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "urdf") ?? .xml, .xml]) { result in
            if case .success(let url) = result {
                robots.importURDF(at: url)
                if robots.error == nil { dismiss() }
            }
        }
    }
}
