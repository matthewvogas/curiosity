import SwiftUI

/// Un robot real (SO-101). Lo principal: enseñarle una tarea en tres pasos (demostraciones, entrenar,
/// probar). Lo secundario va en la toolbar: moverlo con el leader y sus ajustes. Todo lo que mueve el
/// robot pide confirmación; los valores por defecto se pueden cambiar en «Opciones» de cada paso.
struct DeviceScreen: View {
    let device: Device
    @Environment(UseDevices.self) private var devices
    @Environment(UseLeRobot.self) private var lerobot
    @Environment(UseDatasets.self) private var datasets
    @Environment(UseTraining.self) private var training
    @Environment(UseTasks.self) private var tasks

    enum Action { case teleop, record, run }
    @State private var confirm: Action?
    @State private var showingSettings = false
    @State private var showingHub = false
    @State private var snapshot: Data?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(device.name.isEmpty ? (device.guess ?? "SO-101") : device.name)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .task { await lerobot.start(); applyDefaults(); await datasets.load() }
            .onChange(of: lerobot.status) { applyDefaults() }
            .onChange(of: lerobot.session?.active) { _, active in if active == false { Task { await datasets.load() } } }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingHub) { hubSheet }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button(confirmButton) {
                    let action = confirm   // el diálogo borra `confirm` al cerrarse
                    Task { await run(action) }
                }
            } message: { Text(confirmMessage) }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        if let s = lerobot.session, s.active, s.kind == "record" {
            RecordingView(session: s, frame: lerobot.frame, onNext: lerobot.next, onRedo: lerobot.redo, onStop: lerobot.stop)
        } else if let s = lerobot.session, s.active, s.kind == "rollout" {
            RunningView(session: s, frame: lerobot.frame, onStop: lerobot.stop)
        } else if let task = tasks.selected(for: device.id) {
            ScrollView { taskFlow(task).padding(Theme.Space.xxl) }
        } else if tasks.tasks(for: device.id).isEmpty {
            TaskEmptyState { title in tasks.add(title: title, deviceID: device.id) }
        } else {
            RobotOverview(tasks: overviewTasks, datasets: datasets.local, models: overviewModels, canRun: device.canRunPolicy && !lerobot.isBusy,
                          onOpenTask: { tasks.selectedID = $0 },
                          onNewTask: { tasks.composingFor = device.id },
                          onRevealDataset: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.root)]) },
                          onRunModel: { runJob = $0; confirm = .run })
        }
    }

    private var overviewTasks: [OverviewTask] {
        tasks.tasks(for: device.id).map { t in
            let s = TaskStatus.of(t, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
            return OverviewTask(id: t.id, title: t.title, summary: s.summary(t), phase: s.phase,
                                fraction: s.isTraining ? s.progress?.fraction : nil)
        }
    }

    private var overviewModels: [OverviewModel] {
        training.jobs.map { j in
            let p = training.progress[j.name]
            let title = tasks.tasks.first { j.name == $0.trainName || j.name.hasPrefix($0.trainName + "_") }?.title ?? j.name
            return OverviewModel(id: j.name, title: title,
                                 detail: "\(policyName(j.policy)) · \(j.steps.formatted()) pasos · \(j.dataset) · \(j.started.formatted(date: .abbreviated, time: .omitted))",
                                 ready: p?.hasModel == true, training: p?.running == true)
        }
    }

    private func taskFlow(_ task: TeachTask) -> some View {
        let demos = demosRecorded(task)
        let job = trainingJob(task)
        let progress = job.flatMap { training.progress[$0.name] }
        let hasModel = progress?.hasModel == true
        let training_ = progress?.running == true
        return VStack(alignment: .leading, spacing: Theme.Space.l) {
            taskHeader(task)
            if let note = notice { Text(note).font(.callout).foregroundStyle(Theme.red) }

            // 1. Demostraciones
            StepCard(number: 1, title: "Mostrarle la tarea", state: task.hubDataset || demos >= task.episodes ? .done : .current,
                     status: task.hubDataset ? "Usa las demostraciones de \(task.dataset) (Hugging Face)."
                           : demos == 0 ? "Graba \(task.episodes) demostraciones con el leader, de unos \(Int(task.episodeSeconds)) s cada una."
                           : "\(demos) de \(task.episodes) demostraciones grabadas.",
                     help: "Mueves el leader y el follower hace la tarea; LeRobot guarda la cámara y los movimientos. Varía un poco la posición de los objetos entre demostraciones.") {
                HStack {
                    if task.hubDataset {
                        Button("Grabar las mías en su lugar") { tasks.update(task.id) { $0.hubDataset = false; $0.dataset = Naming.slug($0.title) } }
                    } else {
                        Button(demos == 0 ? "Grabar demostraciones" : "Seguir grabando") { confirm = .record }
                            .prominent(demos < task.episodes)
                            .disabled(!device.canRecord || lerobot.isBusy)
                            .help(device.canRecord ? "Graba \(task.episodes - demos) más (→ terminar, ← repetir, Esc guardar)" : "Configura el leader y la cámara en Ajustes del robot")
                        Button("o usar datos de Hugging Face") { showingHub = true; Task { if datasets.hub.isEmpty { await datasets.search() } } }
                            .buttonStyle(.link)
                    }
                }
                if !device.canRecord && !task.hubDataset {
                    Button("Configura el leader y la cámara") { showingSettings = true }.buttonStyle(.link).font(.callout)
                }
            } options: {
                Stepper("Demostraciones: \(task.episodes)", value: bind(task, \.episodes), in: 5...300, step: 5)
                    .help("Más demostraciones, más variadas, suelen ayudar más que entrenar más tiempo.")
                Stepper("Hasta \(Int(task.episodeSeconds)) s cada una", value: bind(task, \.episodeSeconds), in: 10...300, step: 5)
                Stepper("\(Int(task.resetSeconds)) s para reacomodar", value: bind(task, \.resetSeconds), in: 0...120, step: 5)
            }

            // 2. Entrenar
            StepCard(number: 2, title: "Entrenarlo",
                     state: hasModel && !training_ ? .done : (demos > 0 || task.hubDataset) ? .current : .waiting,
                     status: trainStatus(task, demos: demos, progress: progress),
                     help: "Una red aprende a imitar tus demostraciones. Corre en tu Mac, aunque cierres la app; déjala enchufada.") {
                if training_, let p = progress {
                    ProgressView(value: p.fraction)
                    Button("Detener") { if let job { training.stop(job) } }
                } else {
                    Button(hasModel ? "Entrenar de nuevo" : "Entrenar · \(eta(task))") { startTraining(task) }
                        .prominent(!hasModel && (demos >= task.episodes || task.hubDataset))
                        .disabled(demos == 0 && !task.hubDataset)
                        .help("\(policyName(task.policy)), \(task.steps.formatted()) pasos")
                }
            } options: {
                Picker("Modelo", selection: bind(task, \.policy)) {
                    ForEach(PolicyOption.all) { p in
                        Text(p.needsSmolVLA && lerobot.env?.smolvla != true ? "\(p.name) (falta instalar)" : p.name).tag(p.id)
                    }
                }
                .help(PolicyOption.all.first { $0.id == task.policy }?.detail ?? "")
                Stepper("Pasos: \(task.steps.formatted())", value: bind(task, \.steps), in: 1000...200_000, step: 1000)
                    .help("Cuántas veces ajusta la red. 20 000 es un buen punto de partida para ACT.")
                Stepper("Lote: \(task.batchSize)", value: bind(task, \.batchSize), in: 1...64)
                    .help("Ejemplos por paso. Más grande, más memoria.")
            }

            // 3. Probar
            StepCard(number: 3, title: "Que lo haga solo", state: hasModel ? .current : .waiting,
                     status: hasModel ? "El robot hace la tarea con lo que aprendió, durante \(Int(task.runSeconds)) s."
                                      : "Disponible cuando termine el entrenamiento.",
                     help: "El robot se mueve solo. Quédate cerca de la fuente; Esc lo detiene y vuelve a su pose inicial.") {
                Button("Probar en el robot") { runJob = nil; confirm = .run }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.canRunPolicy || lerobot.isBusy || !hasModel)
            } options: {
                Stepper("Durante \(Int(task.runSeconds)) s", value: bind(task, \.runSeconds), in: 10...600, step: 10)
            }
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
    }

    private func taskHeader(_ task: TeachTask) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Button { tasks.selectedID = nil } label: {
                    Label("Todas las tareas", systemImage: "chevron.left").font(.caption)
                }
                .buttonStyle(.link)
                .help("Volver al resumen del robot")
                Text(task.title).font(.title2.weight(.semibold))
            }
            Spacer()
            Menu {
                Button("Quitar esta tarea", role: .destructive) { tasks.remove(task.id) }
            } label: {
                Icon(name: .more, size: 16)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Más")
            .accessibilityLabel("Más opciones de la tarea")
        }
    }

    @State private var runJob: String?

    // MARK: - Toolbar y hojas

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if lerobot.session?.active == true && lerobot.session?.kind == "teleop" {
                Button { lerobot.stop() } label: { Label("Dejar de mover", systemImage: "stop.fill") }
                    .labelStyle(.titleAndIcon)
                    .help("Suelta los motores del follower")
            } else {
                Button { confirm = .teleop } label: { Label("Mover con el leader", systemImage: "arrow.left.arrow.right") }
                    .labelStyle(.titleAndIcon)
                    .disabled(!device.canTeleoperate || lerobot.isBusy)
                    .help(device.canTeleoperate ? "El follower copia al leader. No graba nada." : "Configura el leader en Ajustes del robot")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showingSettings = true } label: { Label("Ajustes del robot", systemImage: IconName.settings.rawValue) }
                .help("Conexión, brazos y cámara")
        }
    }

    private var settingsSheet: some View {
        VStack(spacing: 0) {
            Form {
                HardwareTestView(
                    port: device.id,
                    name: Binding(get: { device.name }, set: { v in devices.update(device.id) { $0.name = v } }),
                    placeholder: device.guess ?? "SO-101", connected: devices.isConnected(device.id),
                    testing: devices.isProbing, progress: probeProgress, result: probeResult, resultIsError: probeError,
                    found: device.found, onTest: { Task { await devices.test(device.id) } })
                RobotSetupView(
                    followers: lerobot.calibrations.followers, leaders: lerobot.calibrations.leaders,
                    otherPorts: devices.connectedPorts.filter { $0 != device.id }, cameras: lerobot.cameras,
                    followerID: bindDevice(\.followerID), leaderPort: bindDevice(\.leaderPort), leaderID: bindDevice(\.leaderID),
                    cameraIndex: bindDevice(\.cameraIndex), snapshot: snapshot,
                    onSnapshot: { Task { if let i = device.cameraIndex { snapshot = await lerobot.snapshot(i) } } })
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Listo") { showingSettings = false }.keyboardShortcut(.defaultAction) }
                .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 620)
    }

    @ViewBuilder
    private var hubSheet: some View {
        @Bindable var datasets = datasets
        HubPickerView(results: datasets.hub, query: $datasets.query, searching: datasets.searching,
                      onSearch: { Task { await datasets.search() } },
                      onPick: { d in
                          if let task = tasks.selected(for: device.id) { tasks.update(task.id) { $0.hubDataset = true; $0.dataset = d.id } }
                          showingHub = false
                      },
                      onClose: { showingHub = false })
    }

    // MARK: - Acciones

    private func run(_ action: Action?) async {
        // «Probar» desde el resumen: un modelo concreto, aunque no haya una tarea abierta.
        if action == .run, let name = runJob, let job = training.jobs.first(where: { $0.name == name }) {
            runJob = nil
            let task = tasks.tasks.first { name == $0.trainName || name.hasPrefix($0.trainName + "_") }
            await lerobot.runPolicy(device, modelPath: job.modelPath, task: task?.title ?? job.dataset, seconds: task?.runSeconds ?? 60)
            return
        }
        guard let task = tasks.selected(for: device.id) else {
            if action == .teleop { await lerobot.teleoperate(device) }
            return
        }
        switch action {
        case .teleop: await lerobot.teleoperate(device)
        case .record:
            let remaining = max(1, task.episodes - demosRecorded(task))
            await lerobot.record(device, dataset: task.dataset, task: task.title, episodes: remaining,
                                 episodeSeconds: task.episodeSeconds, resetSeconds: task.resetSeconds)
        case .run:
            if let job = trainingJob(task) {
                await lerobot.runPolicy(device, modelPath: job.modelPath, task: task.title, seconds: task.runSeconds)
            }
        case nil: break
        }
    }

    private func startTraining(_ task: TeachTask) {
        let name = Naming.unique(task.trainName, taken: Set(training.jobs.map(\.name)))
        let root = task.hubDataset ? nil : AppPaths.datasets.appendingPathComponent(task.dataset).path
        let policy = PolicyOption.all.first { $0.id == task.policy } ?? PolicyOption.all[0]
        training.start(name: name, dataset: task.repoID, datasetRoot: root, policy: policy, steps: task.steps, batchSize: task.batchSize)
    }

    /// Lo que se puede deducir se elige solo: calibraciones únicas y la cámara externa.
    private func applyDefaults() {
        guard lerobot.status == .ready else { return }
        devices.update(device.id) { d in
            if d.followerID == nil, lerobot.calibrations.followers.count == 1 { d.followerID = lerobot.calibrations.followers[0] }
            if d.leaderID == nil, d.leaderPort != nil, lerobot.calibrations.leaders.count == 1 { d.leaderID = lerobot.calibrations.leaders[0] }
            if d.cameraIndex == nil {
                let external = lerobot.cameras.first { !$0.name.contains("MacBook") && !$0.name.contains("iPhone") }
                d.cameraIndex = (external ?? lerobot.cameras.first)?.index
                d.cameraName = (external ?? lerobot.cameras.first)?.name
            }
        }
    }

    // MARK: - Estado

    private func demosRecorded(_ task: TeachTask) -> Int { status(task).demos }

    private func trainingJob(_ task: TeachTask) -> TrainJob? { status(task).job }

    private func status(_ task: TeachTask) -> TaskStatus {
        TaskStatus.of(task, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
    }

    private func trainStatus(_ task: TeachTask, demos: Int, progress: TrainProgress?) -> String {
        if let p = progress {
            if p.running { return "Entrenando: paso \(p.step.formatted()) de \((p.total ?? task.steps).formatted())\(p.remaining.map { ", faltan \($0)" } ?? "")." }
            if p.hasModel { return "Modelo listo." }
            if let e = p.error { return "Se detuvo: \(e)" }
        }
        if demos == 0 && !task.hubDataset { return "Primero graba las demostraciones." }
        if !task.hubDataset && demos < task.episodes { return "Puedes entrenar ya con \(demos), pero con \(task.episodes) aprende mejor." }
        return "Listo para entrenar con \(policyName(task.policy))."
    }

    private func eta(_ task: TeachTask) -> String {
        // ACT en una Mac con chip M: ~0,6 s por paso (medido con el SO-101).
        let hours = Double(task.steps) * (task.policy == "act" ? 0.6 : 1.5) / 3600
        return hours < 1 ? "menos de 1 h" : "unas \(Int(hours.rounded())) h"
    }

    private func policyName(_ id: String) -> String { PolicyOption.all.first { $0.id == id }?.name ?? id.uppercased() }

    private var notice: String? { training.message ?? lerobot.error ?? lerobotStatusError }

    private var lerobotStatusError: String? {
        if case .failed(let reason) = lerobot.status { return "LeRobot no arrancó: \(reason)" }
        return nil
    }

    private var subtitle: String {
        if lerobot.status == .starting { return "Cargando LeRobot…" }
        if lerobot.session?.active == true && lerobot.session?.kind == "teleop" { return "Moviendo con el leader" }
        return devices.isConnected(device.id) ? (device.leaderPort == nil ? "Enchufado" : "Enchufado · con leader") : "Desenchufado"
    }

    // MARK: - Confirmaciones

    private var confirmTitle: String {
        switch confirm {
        case .teleop: "¿Mover con el leader?"
        case .record: "¿Empezar a grabar?"
        case .run: "¿Dejar que el robot lo haga solo?"
        case nil: ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .teleop: "Mover"
        case .record: "Grabar"
        case .run: "Probar en el robot"
        case nil: "Aceptar"
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .teleop, .record:
            "El follower va a copiar al leader en cuanto se conecte. Pon el leader en una pose parecida a la del follower, con las fuentes encendidas."
        case .run:
            "El robot se va a mover solo. Despeja la mesa y quédate cerca de la fuente; Esc lo detiene."
        case nil: ""
        }
    }

    // MARK: - Enlaces

    private func bind<T>(_ task: TeachTask, _ key: WritableKeyPath<TeachTask, T>) -> Binding<T> {
        Binding(get: { tasks.tasks.first { $0.id == task.id }?[keyPath: key] ?? task[keyPath: key] },
                set: { v in tasks.update(task.id) { $0[keyPath: key] = v } })
    }

    private func bindDevice<T>(_ key: WritableKeyPath<Device, T>) -> Binding<T> {
        Binding(get: { device[keyPath: key] }, set: { v in devices.update(device.id) { $0[keyPath: key] = v } })
    }

    private var probeProgress: Double { if case .running(let p) = devices.probe { p } else { 0 } }

    private var probeResult: String? {
        if case .failed(let m) = devices.probe { return m }
        guard let at = device.probedAt else { return nil }
        let when = at.formatted(date: .omitted, time: .shortened)
        return device.found.isEmpty ? "No respondió ningún motor (\(when)). Revisa que tenga la fuente encendida."
                                    : "Conexión correcta: \(device.found.count) motores respondieron (\(when))."
    }

    private var probeError: Bool { if case .failed = devices.probe { true } else { false } }
}
