import SwiftUI
import UniformTypeIdentifiers

/// Agregar un robot: uno incluido, de la biblioteca de MuJoCo Menagerie o un archivo URDF / MJCF.
struct AddRobotScreen: View {
    @Environment(UseRobots.self) private var robots
    @Environment(UseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Open simulator").font(.title2.weight(.semibold))
                Text("URDF or MJCF")
                    .font(.callout).foregroundStyle(Theme.muted)
            }

            VStack(spacing: Theme.Space.s) {
                ForEach(robots.included) { robot in
                    OptionCard(icon: .robot, title: robot.name, detail: robot.summary, badge: "Default") {
                        robots.addIncluded(robot)
                        dismiss()
                    }
                }
                Divider().padding(.vertical, Theme.Space.xs)
                OptionCard(icon: .globe, title: "Robot library",
                           detail: "\(library.catalog?.robots.count ?? 0) robots from MuJoCo Menagerie") {
                    browsing = true
                }
                OptionCard(icon: .file, title: "Import a file",
                           detail: ".urdf or .xml") {
                    importing = true
                }
            }

            if let error = robots.error {
                Label(error, systemImage: IconName.warning.rawValue).font(.callout).foregroundStyle(Theme.red)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 520)
        .sheet(isPresented: $browsing, onDismiss: { if library.isAddedAny { dismiss() } }) { LibraryScreen() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "urdf") ?? .xml, .xml]) { result in
            if case .success(let url) = result {
                robots.importModel(at: url)
                if robots.error == nil { dismiss() }
            }
        }
    }
}
