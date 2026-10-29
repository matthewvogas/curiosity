import SwiftUI

/// El modelo de órdenes del robot (SmolVLA, π0…): cargarlo en la sesión en vivo, probarlo a mano con una
/// orden en palabras y dejar que la IA del chat lo use para planear. Solo dibuja: todo por props.
struct SkillPanel: View {
    let trained: [(name: String, path: String)]
    @Binding var path: String
    let loaded: SkillModel?
    let loading: Bool
    let error: String?
    @Binding var forAI: Bool
    @Binding var instruction: String
    @Binding var seconds: Double
    let running: SkillRun?
    let last: SkillResult?
    let recent: [String]
    let onLoad: () -> Void
    let onRun: () -> Void
    let onStop: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action model").font(.headline)
                }
                model
                if loaded != nil {
                    Divider()
                    tryIt
                    Divider()
                    Toggle(isOn: $forAI) {
                        Text("The chat AI can use it")
                    }
                    .toggleStyle(.switch).controlSize(.small)
                }
            }
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TextField("Folder or Hub id (lerobot/smolvla_base)", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onLoad)
                Menu {
                    if trained.isEmpty { Text("No trained models yet") }
                    Section("Trained in Curiosity") {
                        ForEach(trained, id: \.path) { m in Button(m.name) { path = m.path } }
                    }
                    Section("Hugging Face") {
                        Button("lerobot/smolvla_base (not fine-tuned)") { path = "lerobot/smolvla_base" }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pick a model")
            }
            HStack(spacing: Theme.Space.s) {
                Button(loaded?.path == path ? "Loaded" : "Load", action: onLoad)
                    .buttonStyle(.glassProminent)
                    .disabled(loading || path.isEmpty || loaded?.path == path || running != nil)
                if loading {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(Theme.muted)
                } else if let loaded {
                    Label("\(loaded.type) · \(loaded.device)", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.green)
                }
            }
            if let note = loaded?.note {
                Text(note).font(.caption).foregroundStyle(Theme.yellow)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Theme.red)
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Try it").font(.headline)
            TextField("pick up the cube and put it in the box", text: $instruction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { if running == nil { onRun() } }
            if !recent.isEmpty {
                FlowChips(items: recent) { instruction = $0 }
            }
            HStack {
                Stepper("Up to \(Int(seconds)) s", value: $seconds, in: 3...60, step: 1)
                    .monospacedDigit()
                Spacer()
                if running != nil {
                    Button("Stop", systemImage: "stop.fill", action: onStop)
                        .buttonStyle(.glassProminent).tint(Theme.red)
                } else {
                    Button("Run", systemImage: "play.fill", action: onRun)
                        .buttonStyle(.glassProminent)
                        .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let running {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(running.elapsed, running.limit), total: max(running.limit, 1))
                    Text("«\(running.instruction)» · \(Int(running.elapsed)) of \(Int(running.limit)) s")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            } else if let last {
                Text("«\(last.instruction)» · \(Self.reason(last.reason)) after \(String(format: "%.1f", last.seconds)) s")
                    .font(.caption).foregroundStyle(last.reason.hasPrefix("error") ? Theme.red : Theme.muted)
            }
        }
    }

    private static func reason(_ r: String) -> String {
        switch r {
        case "time": "time's up"
        case "stopped": "stopped"
        case "interrupted": "cut off by the controls"
        default: r
        }
    }
}

/// Órdenes recientes, para repetirlas con un clic.
private struct FlowChips: View {
    let items: [String]
    let onPick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Button(item) { onPick(item) }
                        .buttonStyle(.plain)
                        .font(.caption).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.fill, in: .capsule)
                }
            }
        }
        .scrollIndicators(.never)
    }
}
