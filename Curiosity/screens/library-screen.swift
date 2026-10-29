import SwiftUI

/// Biblioteca de MuJoCo Menagerie: robots listos para simular, con un clic.
struct LibraryScreen: View {
    @Environment(UseLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.m)]

    var body: some View {
        @Bindable var library = library
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Robot library").font(.title2.weight(.semibold))
                        Text("\(library.catalog?.robots.count ?? 0) robots from MuJoCo Menagerie")
                            .font(.callout).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                HStack(spacing: Theme.Space.s) {
                    TextField("Search", text: $library.search).textFieldStyle(.roundedBorder).frame(width: 200)
                    Picker("Type", selection: $library.category) {
                        Text("All").tag(String?.none)
                        ForEach(library.categories, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                }
                if let error = library.error {
                    Text(error).font(.callout).foregroundStyle(Theme.red)
                }
            }
            .padding(Theme.Space.xl)

            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.Space.m) {
                    ForEach(library.visible) { robot in
                        LibraryCard(name: robot.name, category: robot.category, imageURL: library.imageURL(robot),
                                    added: library.isAdded(robot), progress: library.downloading[robot.id]) {
                            Task { await library.add(robot) }
                        }
                    }
                }
                .padding([.horizontal, .bottom], Theme.Space.xl)
            }
        }
        .frame(width: 820, height: 620)
        .onAppear { library.beginVisit() }
    }
}
