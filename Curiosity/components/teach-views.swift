import SwiftUI

// Enseñarle una tarea al robot real, en tres pasos guiados. Solo dibujan: datos y acciones por props.

/// Sin tareas: una sola pregunta, centrada como los estados vacíos de macOS, con un campo tipo composer.
struct TaskEmptyState: View {
    let onCreate: (String) -> Void
    var onCancel: (() -> Void)? = nil
    @State private var title = ""
    @FocusState private var focused: Bool

    private static let examples = ["Put the red cube in the cup", "Stack the two blocks", "Push the ball to the left"]

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.point.up.left.and.text")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, Theme.Space.xs)
                Text("What do you want it to learn?").font(.title.weight(.semibold))
            }

            HStack(spacing: Theme.Space.s) {
                TextField("Describe the task", text: $title, prompt: Text("Describe the task in one sentence"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(create)
                Button(action: create) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(isEmpty)
                .help("Start (↩)")
            }
            .padding(.leading, Theme.Space.l)
            .padding(.trailing, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 520)

            VStack(spacing: Theme.Space.s) {
                Text("Ideas").font(.caption).foregroundStyle(Theme.faint)
                GlassEffectContainer {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Self.examples, id: \.self) { e in
                            Button(e) { title = e; focused = true }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if let onCancel {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction).padding(Theme.Space.l)
            }
        }
        .onAppear { focused = true }
    }

    private var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { onCreate(t) }
    }
}

/// Grabando: la cámara grande, el contador y tres botones con su tecla.
struct RecordingView: View {
    let session: RobotSession
    let frame: Data?
    let onNext: () -> Void
    let onRedo: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            LivePicture(frame: frame).frame(maxHeight: 420)
            VStack(spacing: Theme.Space.xs) {
                Text(title).font(.title2.weight(.semibold))
                Text(hint).foregroundStyle(Theme.muted)
                if session.limit > 0 {
                    Text(Units.clock(session.remaining)).font(.system(size: 34, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button("Redo", action: onRedo).keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(session.phase != "recording").help("Redo (←)")
                Button(session.phase == "reset" ? "Ready, next" : "Done with this one", action: onNext)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!(session.phase == "recording" || session.phase == "reset")).help("→")
                Button("Stop and save", role: .destructive, action: onStop).keyboardShortcut(.escape, modifiers: [])
                    .help("Save and stop (Esc)")
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 720)
    }

    private var title: String {
        switch session.phase {
        case "starting": "Connecting the arms and camera…"
        case "recording": "Demonstration \(session.episode + 1) of \(session.target)"
        case "reset": "Get ready for the next one"
        case "saving": "Saving…"
        default: ""
        }
    }

    private var hint: String {
        switch session.phase {
        case "recording": "Recording"
        case "reset": "Reset the scene"
        case "starting": "The follower will copy the leader."
        default: ""
        }
    }
}

/// El robot usa el modelo: sus cámaras y el modelo 3D (como en vivo, cada uno se puede ocultar) y un solo
/// botón para detenerlo.
struct RunningView: View {
    let session: RobotSession
    let frames: [String: Data]
    let twin: SimulationQueries
    let onStop: () -> Void

    /// Los paneles ocultos, por nombre («3D» es el modelo), separados por comas.
    @AppStorage("running.hidden") private var hiddenList = ""
    @State private var focused = 0

    private var hidden: Set<String> { Set(hiddenList.split(separator: ",").map(String.init)) }
    private var panels: [String] { (session.cameras.isEmpty ? Array(frames.keys).sorted() : session.cameras) + ["3D"] }
    private var shown: [String] { panels.filter { !hidden.contains($0) } }

    private func toggle(_ key: String) {
        var h = hidden
        if h.contains(key) { h.remove(key) } else { h.insert(key) }
        hiddenList = h.sorted().joined(separator: ",")
        focused = 0
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            if shown.isEmpty {
                Text("All panels hidden")
                    .foregroundStyle(Theme.muted).frame(maxHeight: .infinity)
            } else {
                TileLayout(focused: min(focused, shown.count - 1)) {
                    ForEach(Array(shown.enumerated()), id: \.element) { i, key in
                        Tile(title: key == "3D" ? "3D model" : key, focused: i == min(focused, shown.count - 1), onTap: { focused = i }) {
                            if key == "3D" {
                                SimStage(engine: twin)
                            } else if let frame = frames[key], let image = NSImage(data: frame) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                }
            }
            Text(session.phase == "running" ? "The robot is doing the task · \(Units.clock(session.elapsed)) of \(Units.clock(session.limit))"
                 : session.phase == "returning" ? "Returning to the home pose…" : "Loading the model and connecting…")
                .font(.title3).monospacedDigit()
            HStack {
                Menu {
                    ForEach(panels, id: \.self) { key in
                        Toggle(key == "3D" ? "3D model" : key, isOn: Binding(get: { !hidden.contains(key) }, set: { _ in toggle(key) }))
                    }
                } label: {
                    Label("Show", systemImage: "rectangle.3.group")
                }
                .fixedSize()
                .help("Show or hide panels")
                Button("Stop robot", role: .destructive, action: onStop)
                    .buttonStyle(.borderedProminent).tint(Theme.red).controlSize(.large)
                    .keyboardShortcut(.escape, modifiers: []).help("Esc")
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Buscar un dataset en Hugging Face y usarlo en lugar de grabar.
struct HubPickerView: View {
    let results: [HubDataset]
    @Binding var query: String
    let searching: Bool
    let onSearch: () -> Void
    let onPick: (HubDataset) -> Void
    let onClose: () -> Void
    var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Data from Hugging Face").font(.title2.weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(Theme.muted) }
            HStack {
                TextField("Search", text: $query).textFieldStyle(.roundedBorder).onSubmit(onSearch)
                Button(searching ? "Searching…" : "Search", action: onSearch).disabled(searching)
            }
            List(results) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.id).lineLimit(1)
                        Text("\(d.downloads.formatted()) downloads").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Link(destination: d.url) { Image(systemName: "arrow.up.right.square") }.help("View on Hugging Face")
                    Button("Use") { onPick(d) }
                }
            }
            .frame(minHeight: 280)
            HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.cancelAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560, height: 520)
    }
}

/// La cámara del robot en vivo.
struct LivePicture: View {
    let frame: Data?

    var body: some View {
        Group {
            if let frame, let image = NSImage(data: frame) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Theme.fill).overlay(ProgressView()).aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
    }
}
