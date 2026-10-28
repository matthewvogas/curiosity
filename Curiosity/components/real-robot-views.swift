import SwiftUI

// Pestañas del robot real. Solo dibujan: datos y acciones llegan por props.

/// Cómo se arma el robot: calibraciones de LeRobot, el leader y la cámara.
struct RobotSetupView: View {
    let followers: [String]
    let leaders: [String]
    let otherPorts: [String]
    let cameras: [CameraInfo]
    @Binding var followerID: String?
    @Binding var leaderPort: String?
    @Binding var leaderID: String?
    @Binding var cameraIndex: Int?
    let snapshot: Data?
    let onSnapshot: () -> Void

    var body: some View {
        Section {
            Picker("Calibración del follower", selection: $followerID) {
                Text("Elige…").tag(String?.none)
                ForEach(followers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Puerto del leader", selection: $leaderPort) {
                Text("Sin leader").tag(String?.none)
                ForEach(otherPorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag(String?.some($0)) }
            }
            Picker("Calibración del leader", selection: $leaderID) {
                Text("Elige…").tag(String?.none)
                ForEach(leaders, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .disabled(leaderPort == nil)
            HStack {
                Picker("Cámara", selection: $cameraIndex) {
                    Text("Elige…").tag(Int?.none)
                    ForEach(cameras) { Text("\($0.name) (\($0.index))").tag(Int?.some($0.index)) }
                }
                Button("Ver", action: onSnapshot).disabled(cameraIndex == nil)
            }
            if let snapshot, let image = NSImage(data: snapshot) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200).clipShape(.rect(cornerRadius: 10))
            }
        } header: {
            Text("Brazos y cámara")
        } footer: {
            Text("Las calibraciones son las que hiciste con lerobot-calibrate. Si no aparece ninguna, calibra primero en la terminal (ver la guía).")
                .foregroundStyle(Theme.muted)
        }
    }
}

/// Teleoperar: el follower copia al leader.
struct TeleopPanel: View {
    let session: RobotSession?
    let ready: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        Form {
            Section {
                HStack {
                    StatusLine(session: session, idle: "Mueve el leader con la mano y el follower lo copia. No graba nada.")
                    Spacer()
                    if session?.active == true {
                        Button("Detener", role: .destructive, action: onStop).buttonStyle(.borderedProminent).tint(Theme.red)
                    } else {
                        Button("Teleoperar", action: onStart).buttonStyle(.borderedProminent).disabled(!ready)
                    }
                }
                if let s = session, s.active, !s.joints.isEmpty {
                    ForEach(s.joints.sorted { $0.key < $1.key }, id: \.key) { name, value in
                        LabeledContent(name) { Text(String(format: "%.1f", value)).monospacedDigit() }
                    }
                }
            } footer: {
                if !ready { Text("Elige en Configurar las calibraciones y el puerto del leader.").foregroundStyle(Theme.muted) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Grabar demostraciones con el leader, con la cámara en vivo.
struct RecordPanel: View {
    @Binding var dataset: String
    @Binding var task: String
    @Binding var episodes: Int
    @Binding var episodeSeconds: Double
    @Binding var resetSeconds: Double
    let session: RobotSession?
    let frame: Data?
    let ready: Bool
    let onStart: () -> Void
    let onNext: () -> Void
    let onRedo: () -> Void
    let onStop: () -> Void

    private var recording: Bool { session?.active == true && session?.kind == "record" }

    var body: some View {
        Form {
            if recording, let s = session {
                Section {
                    LivePicture(frame: frame)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(s)).font(.headline)
                            Text(hint(s)).font(.callout).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if s.limit > 0 { Text(Units.clock(s.remaining)).font(.title2.monospacedDigit()) }
                    }
                    HStack {
                        Button(s.phase == "reset" ? "Listo, siguiente" : "Terminar demo", action: onNext)
                            .buttonStyle(.borderedProminent).disabled(!(s.phase == "recording" || s.phase == "reset"))
                        Button("Repetir", action: onRedo).disabled(s.phase != "recording")
                        Spacer()
                        Button("Detener y guardar", role: .destructive, action: onStop)
                    }
                }
            } else {
                Section {
                    TextField("Nombre del dataset", text: $dataset, prompt: Text("cubo_en_vaso"))
                    TextField("Tarea (en palabras)", text: $task, prompt: Text("Pon el cubo rojo dentro del vaso"))
                    Stepper("Demostraciones: \(episodes)", value: $episodes, in: 1...300)
                    Stepper("Hasta \(Int(episodeSeconds)) s por demostración", value: $episodeSeconds, in: 5...300, step: 5)
                    Stepper("\(Int(resetSeconds)) s para reacomodar", value: $resetSeconds, in: 0...120, step: 5)
                } footer: {
                    Text("Se graba con el leader: haces la tarea, el follower la copia y LeRobot guarda la cámara y los movimientos. Varía un poco la posición de los objetos entre demostraciones.")
                        .foregroundStyle(Theme.muted)
                }
                Section {
                    HStack {
                        StatusLine(session: session, idle: ready ? "Listo para grabar." : "Elige en Configurar el leader y la cámara.")
                        Spacer()
                        Button("Empezar a grabar", action: onStart).buttonStyle(.borderedProminent)
                            .disabled(!ready || dataset.isEmpty || task.isEmpty || session?.active == true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func title(_ s: RobotSession) -> String {
        switch s.phase {
        case "starting": "Conectando los brazos y la cámara…"
        case "recording": "Demostración \(s.episode + 1) de \(s.target)"
        case "reset": "Reacomoda la escena"
        case "saving": "Guardando…"
        default: s.phase
        }
    }

    private func hint(_ s: RobotSession) -> String {
        switch s.phase {
        case "recording": "Haz la tarea con el leader. «Terminar demo» si acabas antes."
        case "reset": "No se graba: deja los objetos como al empezar."
        default: ""
        }
    }
}

/// Datasets: los de esta Mac y la búsqueda en Hugging Face.
struct DatasetsPanel: View {
    let local: [DatasetInfo]
    let hub: [HubDataset]
    @Binding var query: String
    let searching: Bool
    let message: String?
    let canPush: Bool
    let onSearch: () -> Void
    let onTrain: (String, String?) -> Void
    let onPush: (DatasetInfo) -> Void
    let onDelete: (DatasetInfo) -> Void

    var body: some View {
        Form {
            if let message { Text(message).foregroundStyle(Theme.muted) }
            Section("En esta Mac") {
                if local.isEmpty { Text("Todavía no hay datasets. Graba uno o baja uno del Hub.").foregroundStyle(Theme.muted) }
                ForEach(local) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).lineLimit(1)
                            Text("\(d.episodes) episodios · \(ByteCountFormatter.string(fromByteCount: Int64(d.bytes), countStyle: .file))\(d.tasks.first.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        Button("Entrenar") { onTrain(d.repoID, d.source == "hub" ? nil : d.root) }
                    }
                    .contextMenu {
                        if d.source == "local" {
                            Button("Subir al Hub (privado)") { onPush(d) }.disabled(!canPush)
                            Divider()
                            Button("Borrar", role: .destructive) { onDelete(d) }
                        }
                    }
                }
            }
            Section {
                HStack {
                    TextField("Buscar en Hugging Face", text: $query).onSubmit(onSearch)
                    Button(searching ? "Buscando…" : "Buscar", action: onSearch).disabled(searching)
                }
                ForEach(hub) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Link(d.id, destination: d.url).lineLimit(1)
                            Text("\(d.downloads.formatted()) descargas · \(d.likes) ♥").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Entrenar") { onTrain(d.id, nil) }
                    }
                }
            } header: {
                Text("Hugging Face")
            } footer: {
                Text("Datasets de LeRobot que otros grabaron. Se bajan solos al entrenar con uno.").foregroundStyle(Theme.muted)
            }
        }
        .formStyle(.grouped)
    }
}

/// Entrenar un modelo y ver los entrenamientos.
struct TrainPanel: View {
    @Binding var name: String
    @Binding var dataset: String
    @Binding var policy: PolicyOption
    @Binding var steps: Int
    @Binding var batchSize: Int
    let datasetChoices: [String]
    let smolvla: Bool
    let jobs: [TrainJob]
    let progress: [String: TrainProgress]
    let message: String?
    let onStart: () -> Void
    let onStop: (TrainJob) -> Void
    let onTry: (TrainJob) -> Void
    let onRemove: (TrainJob) -> Void

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name, prompt: Text("act_cubo_en_vaso"))
                Picker("Dataset", selection: $dataset) {
                    Text("Elige…").tag("")
                    ForEach(datasetChoices, id: \.self) { Text($0).tag($0) }
                }
                Picker("Modelo", selection: $policy) {
                    ForEach(PolicyOption.all) { p in
                        Text(p.needsSmolVLA && !smolvla ? "\(p.name) (falta instalar)" : p.name).tag(p)
                    }
                }
                Text(policy.detail).font(.caption).foregroundStyle(Theme.muted)
                Stepper("Pasos: \(steps.formatted())", value: $steps, in: 1000...200_000, step: 1000)
                Stepper("Lote: \(batchSize)", value: $batchSize, in: 1...64)
                HStack {
                    if let message { Text(message).font(.callout).foregroundStyle(Theme.red) }
                    Spacer()
                    Button("Entrenar", action: onStart).buttonStyle(.borderedProminent)
                        .disabled(name.isEmpty || dataset.isEmpty || (policy.needsSmolVLA && !smolvla))
                }
            } header: {
                Text("Nuevo entrenamiento")
            } footer: {
                Text("ACT con 20 000 pasos tarda unas 3 h en una Mac con chip M. Sigue aunque cierres la app; deja la Mac enchufada.")
                    .foregroundStyle(Theme.muted)
            }
            Section("Entrenamientos") {
                if jobs.isEmpty { Text("Todavía no hay entrenamientos.").foregroundStyle(Theme.muted) }
                ForEach(jobs) { job in
                    let p = progress[job.name] ?? TrainProgress()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.name).font(.headline)
                            Text("\(job.policy.uppercased()) · \(job.dataset)").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                            Spacer()
                            if p.running {
                                Button("Detener") { onStop(job) }
                            } else if p.hasModel {
                                Button("Probar en el robot") { onTry(job) }
                            }
                        }
                        ProgressView(value: p.fraction)
                        Text(summary(p)).font(.caption).monospacedDigit().foregroundStyle(p.error != nil ? Theme.red : Theme.muted)
                    }
                    .contextMenu { Button("Quitar de la lista") { onRemove(job) }.disabled(p.running) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func summary(_ p: TrainProgress) -> String {
        if let e = p.error, !p.running { return e }
        var parts = ["paso \(p.step.formatted()) de \((p.total ?? 0).formatted())"]
        if let l = p.loss { parts.append(String(format: "pérdida %.3f", l)) }
        if p.running, let r = p.remaining { parts.append("faltan \(r)") }
        if p.finished { parts.append("terminado") } else if !p.running { parts.append("detenido") }
        return parts.joined(separator: " · ")
    }
}

/// Probar un modelo entrenado en el robot.
struct RolloutPanel: View {
    let models: [TrainJob]
    @Binding var modelPath: String
    @Binding var task: String
    @Binding var seconds: Double
    let session: RobotSession?
    let frame: Data?
    let ready: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    private var running: Bool { session?.active == true && session?.kind == "rollout" }

    var body: some View {
        Form {
            if running, let s = session {
                Section {
                    LivePicture(frame: frame)
                    HStack {
                        StatusLine(session: s, idle: "")
                        Spacer()
                        if s.phase == "running" { Text("\(Units.clock(s.elapsed)) / \(Units.clock(s.limit))").monospacedDigit() }
                        Button("Detener robot", role: .destructive, action: onStop).buttonStyle(.borderedProminent).tint(Theme.red)
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                }
            } else {
                Section {
                    Picker("Modelo", selection: $modelPath) {
                        Text("Elige…").tag("")
                        ForEach(models) { Text($0.name).tag($0.modelPath) }
                    }
                    TextField("Tarea", text: $task, prompt: Text("Pon el cubo rojo dentro del vaso"))
                    Stepper("Durante \(Int(seconds)) s", value: $seconds, in: 5...600, step: 5)
                } footer: {
                    Text("El robot se mueve solo con el modelo. Quédate al lado con la mano cerca de su fuente; Esc lo detiene. Al terminar vuelve a su pose inicial y suelta los motores.")
                        .foregroundStyle(Theme.muted)
                }
                Section {
                    HStack {
                        StatusLine(session: session, idle: ready ? "Listo." : "Elige en Configurar la calibración del follower y la cámara.")
                        Spacer()
                        Button("Probar en el robot", action: onStart).buttonStyle(.borderedProminent)
                            .disabled(!ready || modelPath.isEmpty || session?.active == true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// La cámara del robot en vivo.
private struct LivePicture: View {
    let frame: Data?

    var body: some View {
        Group {
            if let frame, let image = NSImage(data: frame) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Theme.fill).overlay(ProgressView())
                    .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .frame(maxHeight: 320)
        .clipShape(.rect(cornerRadius: 12))
    }
}

/// Una línea con el estado de lo que corre (o el texto de reposo).
private struct StatusLine: View {
    let session: RobotSession?
    let idle: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let s = session, s.active {
                Circle().fill(Theme.green).frame(width: 8, height: 8)
                Text(label(s)).foregroundStyle(Theme.ink)
            } else if let e = session?.error {
                Circle().fill(Theme.red).frame(width: 8, height: 8)
                Text(e).foregroundStyle(Theme.red).lineLimit(3)
            } else {
                Text(idle).foregroundStyle(Theme.muted)
            }
        }
    }

    private func label(_ s: RobotSession) -> String {
        switch s.phase {
        case "starting": "Conectando…"
        case "running": s.kind == "teleop" ? "Teleoperando · \(Int(s.hz)) Hz" : "El robot está actuando"
        case "returning": "Volviendo a la pose inicial…"
        case "stopping": "Soltando los motores…"
        default: s.phase
        }
    }
}
