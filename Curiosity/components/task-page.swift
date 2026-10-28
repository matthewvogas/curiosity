import SwiftUI

// La página de una tarea: en qué va, qué ve la cámara, el siguiente paso (una sola acción destacada)
// y sus números. Los valores se cambian en el inspector (TaskOptionsForm). Solo dibujan: todo por props.

enum TaskStage: Int { case demos, train, test }

struct TaskPageInfo {
    var title: String
    var subtitle: String
    var stage: TaskStage
    var demos: Int
    var target: Int
    var hubDataset: String?
    var recordedMinutes: Double?
    var fps: Double?
    var datasetName: String
    var policyName: String
    var steps: Int
    var eta: String
    var progress: TrainProgress?
    var hasModel: Bool
    var runSeconds: Int
    var episodeSeconds: Int
    var cameraName: String?
    var picture: Data?
    /// Por qué no se puede hacer la acción principal ahora (falta el leader, la cámara…).
    var blocker: String?
    var busy: Bool
    var notice: String?
}

struct TaskPageActions {
    var onBack: () -> Void
    var onRemove: () -> Void
    var onRecord: () -> Void
    var onHub: () -> Void
    var onTrain: () -> Void
    var onStopTraining: () -> Void
    var onRun: () -> Void
    var onFixSetup: () -> Void
    var onRefreshPicture: () -> Void
    var onRevealData: () -> Void
    var onShowLog: () -> Void
}

struct TaskPage: View {
    let info: TaskPageInfo
    let actions: TaskPageActions

    private var training: Bool { info.progress?.running == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                StageBar(stage: info.stage, details: [demosShort, trainShort, info.hasModel ? "Listo" : "—"])
                if let note = info.notice {
                    Label(note, systemImage: IconName.warning.rawValue).font(.callout).foregroundStyle(Theme.red)
                }
                hero
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    StatCard(title: "Demostraciones", value: info.hubDataset == nil ? "\(info.demos)" : "Hub",
                             unit: info.hubDataset == nil ? "de \(info.target)" : nil,
                             detail: demosDetail,
                             fraction: info.hubDataset == nil ? min(1, Double(info.demos) / Double(max(1, info.target))) : nil,
                             action: info.demos > 0 ? ("Ver en Finder", actions.onRevealData) : nil)
                    StatCard(title: "Entrenamiento", value: training ? "\(Int((info.progress?.fraction ?? 0) * 100)) %" : info.hasModel ? "Listo" : "—",
                             unit: nil, detail: trainDetail,
                             fraction: training ? info.progress?.fraction : nil,
                             action: info.progress != nil ? ("Ver registro", actions.onShowLog) : nil)
                    StatCard(title: "Prueba", value: info.hasModel ? "\(info.runSeconds) s" : "—", unit: info.hasModel ? "por intento" : nil,
                             detail: info.hasModel ? "Esc lo detiene y vuelve a su pose inicial." : "Cuando haya un modelo.",
                             fraction: nil, action: nil)
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Encabezado

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Button(action: actions.onBack) { Label("Todas las tareas", systemImage: "chevron.left").font(.callout) }
                    .buttonStyle(.link)
                Text(info.title).font(.largeTitle.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(info.subtitle).foregroundStyle(Theme.muted)
            }
            Spacer()
            Menu {
                Button("Quitar esta tarea", role: .destructive, action: actions.onRemove)
            } label: { Icon(name: .more, size: 18) }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .help("Más")
        }
    }

    // MARK: Siguiente paso

    private var hero: some View {
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let data = info.picture, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(Theme.fill)
                                .overlay(Icon(name: .camera, size: 22).foregroundStyle(Theme.faint))
                        }
                    }
                    .frame(width: 300, height: 225)
                    .clipShape(.rect(cornerRadius: 12))
                    Button(action: actions.onRefreshPicture) { Icon(name: .reset, size: 12) }
                        .buttonStyle(.glass).buttonBorderShape(.circle).padding(Theme.Space.s)
                        .help("Volver a mirar")
                }
                Text(info.cameraName.map { "Lo que ve: \($0)" } ?? "Sin cámara elegida")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("SIGUIENTE PASO").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).tracking(0.6)
                Text(nextTitle).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(nextPoints, id: \.self) { p in
                        Label(p, systemImage: "checkmark").font(.callout).foregroundStyle(Theme.muted)
                    }
                }
                if training, let p = info.progress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: p.fraction)
                        Text("Paso \(p.step.formatted()) de \((p.total ?? info.steps).formatted())\(p.remaining.map { " · faltan \($0)" } ?? "")")
                            .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if let blocker = info.blocker, !training {
                    HStack {
                        Label(blocker, systemImage: IconName.info.rawValue).font(.callout).foregroundStyle(Theme.muted)
                        Button("Configurar", action: actions.onFixSetup)
                    }
                }
                HStack(spacing: Theme.Space.m) {
                    primary
                    if info.stage == .demos && info.hubDataset == nil {
                        Button("o usar datos de Hugging Face", action: actions.onHub).buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 225, alignment: .topLeading)
        }
        .padding(Theme.Space.xl)
        .background(Theme.fill.opacity(0.5), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
    }

    @ViewBuilder
    private var primary: some View {
        switch (info.stage, training) {
        case (_, true):
            Button("Detener entrenamiento", action: actions.onStopTraining).controlSize(.large)
        case (.demos, _):
            Button(info.demos == 0 ? "Grabar demostraciones" : "Seguir grabando", action: actions.onRecord)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(info.blocker != nil || info.busy)
                .help("→ terminar · ← repetir · Esc guardar")
        case (.train, _):
            Button("Entrenar · \(info.eta)", action: actions.onTrain)
                .buttonStyle(.borderedProminent).controlSize(.large)
        case (.test, _):
            Button("Probar en el robot", action: actions.onRun)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(info.blocker != nil || info.busy)
            Button("Entrenar de nuevo", action: actions.onTrain).controlSize(.large)
        }
    }

    private var nextTitle: String {
        if training { return "Está aprendiendo de tus demostraciones" }
        switch info.stage {
        case .demos: return info.demos == 0 ? "Muéstrale la tarea \(info.target) veces" : "Graba \(info.target - info.demos) demostraciones más"
        case .train: return info.hubDataset == nil ? "Entrénalo con tus \(info.demos) demostraciones" : "Entrénalo con los datos de Hugging Face"
        case .test: return "Ya aprendió. Pruébalo en el robot"
        }
    }

    private var nextPoints: [String] {
        if training { return ["Sigue aunque cierres la app; deja la Mac enchufada.", "Al terminar, este paso cambia a «Probar»."] }
        switch info.stage {
        case .demos: return ["Haz la tarea con el leader de principio a fin, en unos \(info.episodeSeconds) s.",
                             "Mueve un poco el objeto entre una y otra.",
                             "Todo debe verse en la cámara de la izquierda."]
        case .train: return ["\(info.policyName), \(info.steps.formatted()) pasos, en tu Mac.",
                             "Puedes cerrar la app mientras tanto."]
        case .test: return ["Despeja la mesa y deja el objeto como en las demostraciones.",
                            "Quédate cerca de la fuente; Esc lo detiene."]
        }
    }

    // MARK: Números

    private var demosShort: String { info.hubDataset == nil ? "\(info.demos)/\(info.target)" : "Hub" }

    private var trainShort: String {
        if training { return "\(Int((info.progress?.fraction ?? 0) * 100)) %" }
        return info.hasModel ? "Listo" : "—"
    }

    private var demosDetail: String {
        if let hub = info.hubDataset { return hub }
        var parts = [info.datasetName]
        if let m = info.recordedMinutes, m > 0 { parts.append(m < 1 ? "menos de 1 min" : "\(Int(m.rounded())) min") }
        if let fps = info.fps { parts.append("\(Int(fps)) fps") }
        return parts.joined(separator: " · ")
    }

    private var trainDetail: String {
        if training, let p = info.progress {
            return [p.remaining.map { "faltan \($0)" }, p.loss.map { String(format: "pérdida %.3f", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
        if let e = info.progress?.error, !info.hasModel { return "Se detuvo: \(e)" }
        return "\(info.policyName) · \(info.steps.formatted()) pasos"
    }
}

/// Las tres etapas en una línea, como un indicador de avance.
private struct StageBar: View {
    let stage: TaskStage
    let details: [String]

    private let titles = ["Demostraciones", "Entrenar", "Probar"]

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ForEach(0..<3, id: \.self) { i in
                if i > 0 { Rectangle().fill(i <= stage.rawValue ? Theme.ink.opacity(0.35) : Theme.hairline).frame(height: 1) }
                HStack(spacing: Theme.Space.s) {
                    ZStack {
                        Circle().fill(state(i) == .waiting ? Theme.fill : state(i) == .done ? Theme.ink.opacity(0.12) : Theme.ink)
                        if state(i) == .done {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        } else {
                            Text("\(i + 1)").font(.caption.weight(.semibold))
                                .foregroundStyle(state(i) == .current ? Color(nsColor: .windowBackgroundColor) : Theme.muted)
                        }
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(titles[i]).font(.callout).foregroundStyle(state(i) == .waiting ? Theme.muted : Theme.ink)
                        Text(details[i]).font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    }
                }
                .fixedSize()
            }
        }
    }

    private enum State { case done, current, waiting }

    private func state(_ i: Int) -> State {
        if i < stage.rawValue { return .done }
        return i == stage.rawValue ? .current : .waiting
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let unit: String?
    let detail: String
    let fraction: Double?
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                if let unit { Text(unit).font(.callout).foregroundStyle(Theme.muted) }
            }
            if let fraction { ProgressView(value: fraction).controlSize(.small) }
            Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).buttonStyle(.link).font(.caption) }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Theme.fill.opacity(0.5), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }
}

/// El inspector de la tarea: todos sus valores, con lo recomendado ya puesto.
struct TaskOptionsForm: View {
    @Binding var episodes: Int
    @Binding var episodeSeconds: Double
    @Binding var resetSeconds: Double
    @Binding var policy: String
    @Binding var steps: Int
    @Binding var batchSize: Int
    @Binding var runSeconds: Double
    let policies: [(id: String, label: String, detail: String)]
    let dataset: String
    let usesHub: Bool
    let onUseHub: () -> Void
    let onUseOwn: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Dataset", value: dataset)
                if usesHub {
                    Button("Grabar las mías en su lugar", action: onUseOwn)
                } else {
                    Button("Usar datos de Hugging Face…", action: onUseHub)
                }
            } header: { Text("Datos") }

            Section {
                Stepper("\(episodes) demostraciones", value: $episodes, in: 5...300, step: 5)
                Stepper("Hasta \(Int(episodeSeconds)) s cada una", value: $episodeSeconds, in: 10...300, step: 5)
                Stepper("\(Int(resetSeconds)) s para reacomodar", value: $resetSeconds, in: 0...120, step: 5)
            } header: { Text("Demostraciones") } footer: {
                Text("Más demostraciones, y más variadas, suelen ayudar más que entrenar más tiempo.").foregroundStyle(Theme.muted)
            }

            Section {
                Picker("Modelo", selection: $policy) {
                    ForEach(policies, id: \.id) { Text($0.label).tag($0.id) }
                }
                Stepper("\(steps.formatted()) pasos", value: $steps, in: 1000...200_000, step: 1000)
                Stepper("Lote de \(batchSize)", value: $batchSize, in: 1...64)
            } header: { Text("Entrenamiento") } footer: {
                Text(policies.first { $0.id == policy }?.detail ?? "").foregroundStyle(Theme.muted)
            }

            Section {
                Stepper("\(Int(runSeconds)) s por intento", value: $runSeconds, in: 10...600, step: 10)
            } header: { Text("Prueba") }
        }
        .formStyle(.grouped)
    }
}
