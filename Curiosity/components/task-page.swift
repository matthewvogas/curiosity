import SwiftUI

// La página de una tarea, como Ajustes del sistema: tres secciones en orden (demostraciones, entrenamiento,
// prueba), cada una con su estado, sus pocos valores y un botón. Solo dibuja: todo por props.

struct TaskPageInfo {
    var demos: Int
    var hubDataset: String?
    var policies: [(id: String, label: String)]
    var progress: TrainProgress?
    var hasModel: Bool
    /// Medido en entrenamientos anteriores de esta Mac; nil si todavía no hay ninguno.
    var eta: String?
    var canRecord: Bool
    var canRun: Bool
    var busy: Bool
    var notice: String?
}

struct TaskPageActions {
    var onRecord: () -> Void
    var onHub: () -> Void
    var onUseOwn: () -> Void
    var onTrain: () -> Void
    var onStopTraining: () -> Void
    /// Abre el entrenamiento en vivo (nil si todavía no hay ninguno).
    var onWatchTraining: (() -> Void)?
    var onRun: () -> Void
    var onFixSetup: () -> Void
    var onRunSetup: () -> Void
    var onRemove: () -> Void
}

struct TaskPage: View {
    let info: TaskPageInfo
    @Binding var episodes: Int
    @Binding var episodeSeconds: Double
    @Binding var policy: String
    @Binding var steps: Int
    @Binding var runSeconds: Double
    let actions: TaskPageActions

    private var training: Bool { info.progress?.running == true }
    private var hasData: Bool { info.hubDataset != nil || info.demos > 0 }

    var body: some View {
        Form {
            if let note = info.notice {
                Section { Label(note, systemImage: IconName.warning.rawValue).foregroundStyle(Theme.red) }
            }

            Section {
                if let hub = info.hubDataset {
                    LabeledContent("Data from Hugging Face") {
                        if let url = URL(string: "https://huggingface.co/datasets/\(hub)") {
                            Link(destination: url) { Label(hub, systemImage: "arrow.up.right.square") }
                                .help("Open the dataset on Hugging Face")
                        } else {
                            Text(hub)
                        }
                    }
                    Button("Record my own instead", action: actions.onUseOwn)
                } else {
                    LabeledContent("Recorded") {
                        Text("\(info.demos) of \(episodes)").monospacedDigit()
                    }
                    Stepper("Goal: \(episodes)", value: $episodes, in: 5...300, step: 5)
                    Stepper("Up to \(Int(episodeSeconds)) s each", value: $episodeSeconds, in: 10...300, step: 5)
                    HStack {
                        Button("Use data from Hugging Face…", action: actions.onHub).buttonStyle(.link)
                        Spacer()
                        if !info.canRecord { Button("Set up follower and camera…", action: actions.onFixSetup) }
                        Button(info.demos == 0 ? "Record" : "Keep recording", action: actions.onRecord)
                            .buttonStyle(.borderedProminent)
                            .disabled(!info.canRecord || info.busy || info.demos >= episodes)
                    }
                }
            } header: {
                Text("1. Demonstrations")
            } footer: {
                Text("→ finish · ← redo · Esc save")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                LabeledContent("Status", value: trainState)
                if training, let p = info.progress {
                    ProgressView(value: p.fraction)
                }
                Picker("Model", selection: $policy) {
                    ForEach(info.policies, id: \.id) { Text($0.label).tag($0.id) }
                }
                .disabled(training)
                Stepper("\(steps.formatted()) steps", value: $steps, in: 1000...200_000, step: 1000)
                    .disabled(training)
                HStack {
                    if let watch = actions.onWatchTraining {
                        Button(training ? "Watch live" : "View training", action: watch).buttonStyle(.link)
                    }
                    Spacer()
                    if training {
                        Button("Stop", action: actions.onStopTraining)
                    } else {
                        if info.hasModel {
                            Button("Train again", action: actions.onTrain)
                        } else {
                            Button("Train", action: actions.onTrain).buttonStyle(.borderedProminent).disabled(!hasData)
                        }
                    }
                }
            } header: {
                Text("2. Training")
            } footer: {
                Text(hasData ? info.eta ?? "" : "No demonstrations yet.")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                Stepper("\(Int(runSeconds)) s per try", value: $runSeconds, in: 10...600, step: 10)
                HStack {
                    Button("Cameras and arm…", action: actions.onRunSetup).disabled(!info.hasModel)
                    Spacer()
                    Button("Run on the robot", action: actions.onRun)
                        .buttonStyle(.borderedProminent)
                        .disabled(!info.hasModel || training || !info.canRun || info.busy)
                }
            } header: {
                Text("3. Run")
            } footer: {
                Text(runHint).foregroundStyle(Theme.muted)
            }

            Section {
                Button("Remove task", role: .destructive, action: actions.onRemove)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    /// Por qué «Run on the robot» está apagado, o qué esperar cuando no lo está.
    private var runHint: String {
        if !info.hasModel { return "Available once training finishes." }
        if training { return "Wait for the training to finish." }
        if !info.canRun { return "Set up the follower and camera first." }
        if info.busy { return "Stop Live or moving with the leader first." }
        return "Esc stops it."
    }

    private var trainState: String {
        if training, let p = info.progress {
            return "\(Int(p.fraction * 100)) %\(p.remaining.map { " · \($0) left" } ?? "")"
        }
        if info.hasModel { return "Ready" }
        if let e = info.progress?.error { return "Stopped: \(e)" }
        return "Not trained"
    }
}
