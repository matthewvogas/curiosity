import SwiftUI

/// Un robot real (SO-101). Lo principal: enseñarle una tarea en tres pasos (demostraciones, entrenar,
/// probar). Lo secundario va en la toolbar: moverlo con el leader y sus ajustes. Todo lo que mueve el
/// robot pide confirmación; los valores por defecto se cambian en el inspector de la tarea.
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
    @State private var showingOptions = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(device.name.isEmpty ? (device.guess ?? "SO-101") : device.name)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .inspector(isPresented: Binding(get: { showingOptions && openTask != nil }, set: { showingOptions = $0 })) {
                if let task = openTask { taskOptions(task).inspectorColumnWidth(min: 260, ideal: 300, max: 380) }
            }
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
            taskPage(task)
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

    private func taskPage(_ task: TeachTask) -> some View {
        let s = status(task)
        let dataset = datasets.local.first { $0.source == (task.hubDataset ? "hub" : "local") && $0.name == task.dataset }
        let stage: TaskStage = s.isTraining ? .train : s.hasModel ? .test
            : (task.hubDataset || s.demos >= task.episodes) ? .train : .demos
        let blocker: String? = switch stage {
        case .demos: device.canRecord ? nil : "Falta elegir el leader o la cámara."
        case .test: device.canRunPolicy ? nil : "Falta elegir la cámara."
        case .train: nil
        }
        let info = TaskPageInfo(
            title: task.title,
            subtitle: "\(device.name.isEmpty ? (device.guess ?? "SO-101") : device.name) · creada el \(task.createdAt.formatted(date: .long, time: .omitted))",
            stage: stage, demos: s.demos, target: task.episodes, hubDataset: task.hubDataset ? task.dataset : nil,
            recordedMinutes: dataset.flatMap { d in d.fps.map { Double(d.frames) / $0 / 60 } }, fps: dataset?.fps,
            datasetName: task.dataset, policyName: policyName(task.policy), steps: task.steps, eta: eta(task),
            progress: s.progress, hasModel: s.hasModel, runSeconds: Int(task.runSeconds), episodeSeconds: Int(task.episodeSeconds),
            cameraName: device.cameraName, picture: snapshot, blocker: blocker, busy: lerobot.isBusy, notice: notice)
        let actions = TaskPageActions(
            onBack: { tasks.selectedID = nil },
            onRemove: { tasks.remove(task.id) },
            onRecord: { confirm = .record },
            onHub: openHub,
            onTrain: { startTraining(task) },
            onStopTraining: { if let job = s.job { training.stop(job) } },
            onRun: { runJob = nil; confirm = .run },
            onFixSetup: { showingSettings = true },
            onRefreshPicture: refreshPicture,
            onRevealData: { if let d = dataset { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: d.root)]) } },
            onShowLog: { if let job = s.job { NSWorkspace.shared.open(URL(fileURLWithPath: job.log)) } })
        return TaskPage(info: info, actions: actions)
            .task(id: task.id) { refreshPicture() }
    }

    private func taskOptions(_ task: TeachTask) -> some View {
        TaskOptionsForm(
            episodes: bind(task, \.episodes), episodeSeconds: bind(task, \.episodeSeconds), resetSeconds: bind(task, \.resetSeconds),
            policy: bind(task, \.policy), steps: bind(task, \.steps), batchSize: bind(task, \.batchSize), runSeconds: bind(task, \.runSeconds),
            policies: PolicyOption.all.map { p in
                (p.id, p.needsSmolVLA && lerobot.env?.smolvla != true ? "\(p.name) (falta instalar)" : p.name, p.detail)
            },
            dataset: task.hubDataset ? task.dataset : "local/\(task.dataset)", usesHub: task.hubDataset,
            onUseHub: openHub,
            onUseOwn: { tasks.update(task.id) { $0.hubDataset = false; $0.dataset = Naming.slug($0.title) } })
    }

    private func openHub() {
        showingHub = true
        Task { if datasets.hub.isEmpty { await datasets.search() } }
    }

    private func refreshPicture() {
        guard let i = device.cameraIndex, lerobot.status == .ready, !lerobot.isBusy else { return }
        Task { snapshot = await lerobot.snapshot(i) }
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
        if openTask != nil {
            ToolbarItem(placement: .primaryAction) {
                Button { showingOptions.toggle() } label: { Label("Opciones de la tarea", systemImage: IconName.sliders.rawValue) }
                    .help("Demostraciones, modelo, pasos y duración de la prueba")
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

    private var openTask: TeachTask? {
        guard lerobot.session?.active != true || lerobot.session?.kind == "teleop" else { return nil }
        return tasks.selected(for: device.id)
    }

    private func demosRecorded(_ task: TeachTask) -> Int { status(task).demos }

    private func trainingJob(_ task: TeachTask) -> TrainJob? { status(task).job }

    private func status(_ task: TeachTask) -> TaskStatus {
        TaskStatus.of(task, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
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
