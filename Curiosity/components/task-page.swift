import SwiftUI

// La página de una tarea, como Ajustes del sistema: tres secciones en orden (demostraciones, entrenamiento,
// prueba), cada una con su estado, sus pocos valores y un botón. Solo dibuja: todo por props.

struct TaskPageInfo {
    var demos: Int
    var hubDataset: String?
    var policies: [(id: String, label: String)]
    var progress: TrainProgress?
    var hasModel: Bool
    var eta: String
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
                    LabeledContent("Datos de Hugging Face", value: hub)
                    Button("Grabar las mías en su lugar", action: actions.onUseOwn)
                } else {
                    LabeledContent("Grabadas") {
                        Text("\(info.demos) de \(episodes)").monospacedDigit()
                    }
                    Stepper("Quiero \(episodes)", value: $episodes, in: 5...300, step: 5)
                    Stepper("Hasta \(Int(episodeSeconds)) s cada una", value: $episodeSeconds, in: 10...300, step: 5)
                    HStack {
                        Button("Usar datos de Hugging Face…", action: actions.onHub).buttonStyle(.link)
                        Spacer()
                        if !info.canRecord { Button("Configurar leader y cámara…", action: actions.onFixSetup) }
                        Button(info.demos == 0 ? "Grabar" : "Seguir grabando", action: actions.onRecord)
                            .buttonStyle(.borderedProminent)
                            .disabled(!info.canRecord || info.busy || info.demos >= episodes)
                    }
                }
            } header: {
                Text("1. Demostraciones")
            } footer: {
                Text("Haz la tarea con el leader de principio a fin y mueve un poco el objeto entre una y otra. Teclas: → terminar, ← repetir, Esc guardar.")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                LabeledContent("Estado", value: trainState)
                if training, let p = info.progress {
                    ProgressView(value: p.fraction)
                }
                Picker("Modelo", selection: $policy) {
                    ForEach(info.policies, id: \.id) { Text($0.label).tag($0.id) }
                }
                .disabled(training)
                Stepper("\(steps.formatted()) pasos", value: $steps, in: 1000...200_000, step: 1000)
                    .disabled(training)
                HStack {
                    if let watch = actions.onWatchTraining {
                        Button(training ? "Ver en vivo" : "Ver entrenamiento", action: watch).buttonStyle(.link)
                    }
                    Spacer()
                    if training {
                        Button("Detener", action: actions.onStopTraining)
                    } else {
                        if info.hasModel {
                            Button("Entrenar de nuevo", action: actions.onTrain)
                        } else {
                            Button("Entrenar", action: actions.onTrain).buttonStyle(.borderedProminent).disabled(!hasData)
                        }
                    }
                }
            } header: {
                Text("2. Entrenamiento")
            } footer: {
                Text(hasData ? "Tarda \(info.eta) en tu Mac y sigue aunque cierres la app." : "Primero graba algunas demostraciones.")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                Stepper("\(Int(runSeconds)) s por intento", value: $runSeconds, in: 10...600, step: 10)
                HStack {
                    Spacer()
                    Button("Probar en el robot", action: actions.onRun)
                        .buttonStyle(.borderedProminent)
                        .disabled(!info.hasModel || training || !info.canRun || info.busy)
                }
            } header: {
                Text("3. Prueba")
            } footer: {
                Text(info.hasModel ? "El robot se mueve solo. Despeja la mesa; Esc lo detiene." : "Disponible cuando termine el entrenamiento.")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                Button("Quitar tarea", role: .destructive, action: actions.onRemove)
            } footer: {
                Text("Las demostraciones y el modelo se quedan en tu Mac.").foregroundStyle(Theme.muted)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private var trainState: String {
        if training, let p = info.progress {
            return "\(Int(p.fraction * 100)) %\(p.remaining.map { " · faltan \($0)" } ?? "")"
        }
        if info.hasModel { return "Listo" }
        if let e = info.progress?.error { return "Se detuvo: \(e)" }
        return "Sin entrenar"
    }
}
