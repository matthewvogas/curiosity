import SwiftUI

/// Un robot real (cualquiera de LeRobot). Lo principal: enseñarle una tarea en tres pasos (demostraciones, entrenar,
/// probar). Lo secundario va en la toolbar: moverlo con el leader y sus ajustes. Todo lo que mueve el
/// robot pide confirmación; los valores por defecto se cambian en la misma página de la tarea.
struct DeviceScreen: View {
    let device: Device
    @Environment(UseDevices.self) private var devices
    @Environment(UseLeRobot.self) private var lerobot
    @Environment(UseDatasets.self) private var datasets
    @Environment(UseTraining.self) private var training
    @Environment(UseTasks.self) private var tasks
    @Environment(UseLiveRobot.self) private var live
    @Environment(\.liveChat) private var liveChat

    enum Action { case teleop, record, run, live }
    enum Mode: String { case teach, live }
    @State private var mode: Mode = .teach
    /// En una tarea: sus pasos o su página de notas.
    @AppStorage("task.tab") private var taskTab = "steps"
    @State private var confirm: Action?
    @State private var showingSettings = false
    @State private var showingHub = false
    @State private var runSetupJob: TrainJob?
    @State private var previews: [Int: Data] = [:]
    @State private var snapshot: Data?
    @State private var deleting: DatasetInfo?
    // Revisión previa (grabar o probar): cada pieza, sin mover nada.
    @State private var preflightFor: Action?
    @State private var checks: [PreflightCheck] = []
    @State private var checking = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(openTask?.title ?? deviceName)
            .navigationSubtitle(openTask == nil ? subtitle : deviceName)
            .toolbar { toolbar }
            .task { await lerobot.start(); applyDefaults(); await datasets.load() }
            .onChange(of: lerobot.status) { applyDefaults() }
            .onChange(of: lerobot.session?.active) { _, active in if active == false { Task { await datasets.load() } } }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingHub) { hubSheet }
            .sheet(item: $runSetupJob) { job in runSetupSheet(job) }
            .sheet(isPresented: Binding(get: { training.watched != nil }, set: { if !$0 { training.watch(nil) } })) {
                liveTraining
            }
            .sheet(isPresented: Binding(get: { preflightFor != nil }, set: { if !$0 { preflightFor = nil } })) {
                PreflightView(
                    title: preflightTitle, checks: checks,
                    leader: preflightFor == .record || preflightFor == .teleop
                        ? PreflightLeader(ports: devices.connectedPorts.filter { $0 != device.id }, calibrations: lerobot.leaders(device),
                                          port: bindDevice(\.leaderPort), id: bindDevice(\.leaderID))
                        : nil,
                    checking: checking,
                    warning: preflightFor.map(message) ?? "",
                    startTitle: preflightFor.map(confirmButtonTitle) ?? "Start",
                    onRetry: { if let a = preflightFor { check(a) } },
                    onStart: {
                        let action = preflightFor
                        preflightFor = nil
                        Task { await run(action) }
                    },
                    onCancel: { preflightFor = nil },
                    onFix: { key in
                        let action = preflightFor
                        preflightFor = nil
                        // Las cámaras de un modelo se eligen en «Cameras and arm…»; lo demás, en los ajustes.
                        if action == .run, key == "cameras" || key == "camera" || key.hasPrefix("cam"), let job = runTarget {
                            runSetupJob = job
                        } else {
                            showingSettings = true
                        }
                    },
                    onOpenPrivacy: { NSWorkspace.shared.open(PermissionQueries.cameraSettings) })
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button(confirmButton) {
                    let action = confirm   // el diálogo borra `confirm` al cerrarse
                    Task { await run(action) }
                }
            } message: { Text(confirmMessage) }
            .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete", role: .destructive) {
                    let d = deleting   // el diálogo borra `deleting` al cerrarse
                    Task { if let d { await datasets.delete(d) } }
                }
            } message: {
                Text(deleting?.source == "hub"
                     ? "It stays on Hugging Face."
                     : "\(deleting?.episodes ?? 0) demonstrations. This can’t be undone.")
            }
    }

    // MARK: - Contenido

    @ViewBuilder
    private var content: some View {
        if mode == .live || live.isLive {
            DeviceLiveScreen(device: device, robotName: deviceName, onConnect: { check(.live) })
        } else if let s = lerobot.session, s.active, s.kind == "record" {
            RecordingView(session: s, frame: lerobot.frame, onNext: lerobot.next, onRedo: lerobot.redo, onStop: lerobot.stop)
        } else if let s = lerobot.session, s.active, s.kind == "rollout" {
            RunningView(session: s, frames: lerobot.frames, twin: live.twin, onStop: lerobot.stop)
        } else if let task = tasks.selected(for: device.id) {
            VStack(spacing: 0) {
                Picker("View", selection: $taskTab) {
                    Text("Steps").tag("steps")
                    Text("Notes").tag("notes")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .padding(.vertical, Theme.Space.s)
                if taskTab == "notes" {
                    // El mismo ancho y márgenes que la página de pasos (TaskPage, Form agrupado).
                    NotePage(url: NoteQueries.url(for: task.id))
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                } else {
                    taskPage(task)
                }
            }
        } else if tasks.tasks(for: device.id).isEmpty {
            TaskEmptyState { title in tasks.add(title: title, deviceID: device.id) }
        } else {
            RobotOverview(tasks: overviewTasks, datasets: datasets.local, models: overviewModels, canRun: device.canRunPolicy && !lerobot.isBusy,
                          onOpenTask: { tasks.selectedID = $0 },
                          onNewTask: { tasks.composingFor = device.id },
                          onRevealDataset: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0.root)]) },
                          onDeleteDataset: { deleting = $0 },
                          onRunModel: { runJob = $0; check(.run) },
                          onOpenModel: { training.watch($0) })
        }
    }

    private var overviewTasks: [OverviewTask] {
        tasks.tasks(for: device.id).map { t in
            let s = TaskStatus.of(t, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
            return OverviewTask(id: t.id, title: t.title, summary: s.summary(t), phase: s.phase,
                                fraction: s.isTraining ? s.progress?.fraction : nil)
        }
    }

    @ViewBuilder
    private var liveTraining: some View {
        if let w = training.watched, let job = training.jobs.first(where: { $0.name == w.name }) {
            TrainingLiveView(title: jobTitle(job), detail: jobDetail(job), progress: training.progress[job.name], watch: w,
                             onStop: { training.stop(job) }, onClose: { training.watch(nil) })
        }
    }

    private func jobTitle(_ job: TrainJob) -> String {
        tasks.tasks.first { job.name == $0.trainName || job.name.hasPrefix($0.trainName + "_") }?.title ?? job.name
    }

    private func jobDetail(_ job: TrainJob) -> String {
        "\(policyName(job.policy)) · \(job.steps.formatted()) steps · batch \(job.batchSize) · \(job.dataset)"
    }

    private var overviewModels: [OverviewModel] {
        training.jobs.map { j in
            let p = training.progress[j.name]
            let title = tasks.tasks.first { j.name == $0.trainName || j.name.hasPrefix($0.trainName + "_") }?.title ?? j.name
            return OverviewModel(id: j.name, title: title,
                                 detail: "\(policyName(j.policy)) · \(j.steps.formatted()) steps · \(j.dataset) · \(j.started.formatted(date: .abbreviated, time: .omitted))",
                                 ready: p?.hasModel == true, training: p?.running == true,
                                 fraction: p?.running == true ? p?.fraction : nil)
        }
    }

    private func taskPage(_ task: TeachTask) -> some View {
        let s = status(task)
        let info = TaskPageInfo(
            demos: s.demos, hubDataset: task.hubDataset ? task.dataset : nil,
            policies: PolicyOption.all.map { p in (p.id, p.needsSmolVLA && lerobot.env?.smolvla != true ? "\(p.name) (not installed)" : p.name) },
            progress: s.progress, hasModel: s.hasModel, eta: eta(task),
            // El leader se elige en la revisión previa: para empezar basta con el follower y la cámara.
            canRecord: device.canRunPolicy, canRun: device.canRunPolicy, busy: lerobot.isBusy, notice: notice)
        let actions = TaskPageActions(
            onRecord: { check(.record) },
            onHub: openHub,
            onUseOwn: { tasks.update(task.id) { $0.hubDataset = false; $0.dataset = Naming.slug($0.title) } },
            onTrain: { startTraining(task) },
            onStopTraining: { if let job = s.job { training.stop(job) } },
            onWatchTraining: s.job.map { job in { training.watch(job.name) } },
            onRun: { runJob = nil; check(.run) },
            onFixSetup: { showingSettings = true },
            onRunSetup: { runSetupJob = s.job },
            onRemove: { tasks.remove(task.id) })
        return TaskPage(info: info, episodes: bind(task, \.episodes), episodeSeconds: bind(task, \.episodeSeconds),
                        policy: bind(task, \.policy), steps: bind(task, \.steps), runSeconds: bind(task, \.runSeconds),
                        actions: actions)
    }

    private func openHub() {
        showingHub = true
        Task { if datasets.hub.isEmpty { await datasets.search() } }
    }

    @State private var runJob: String?

    // MARK: - Toolbar y hojas

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: Binding(get: { live.isLive ? .live : mode }, set: { mode = $0 })) {
                Text("Teach").tag(Mode.teach)
                Text("Live").tag(Mode.live)
            }
            .pickerStyle(.segmented)
            .disabled(live.isLive || (lerobot.isBusy && !live.isLive))
            .help("Teach or control live")
        }
        if live.isLive {
            ToolbarItem(placement: .primaryAction) {
                Button { liveChat?.stop(); live.stop() } label: { Label("Release", systemImage: "stop.fill") }
                    .labelStyle(.titleAndIcon)
                    .disabled(live.isReturning)
                    .help("Return to start and release")
            }
        }
        if !live.isLive && mode == .teach { ToolbarItem(placement: .primaryAction) {
            if lerobot.session?.active == true && lerobot.session?.kind == "teleop" {
                Button { lerobot.stop() } label: { Label("Stop moving", systemImage: "stop.fill") }
                    .help("Releases the follower’s motors")
            } else {
                Button { check(.teleop) } label: { Label("Move with the leader", systemImage: "hand.raised") }
                    .disabled(lerobot.isBusy)
                    .help("Nothing is recorded")
            }
        } }
        ToolbarItem(placement: .primaryAction) {
            Button { showingSettings = true } label: { Label("Robot settings", systemImage: IconName.settings.rawValue) }
                .help("Connection, arms and camera")
        }
    }

    private var settingsSheet: some View {
        VStack(spacing: 0) {
            Form {
                HardwareTestView(
                    port: device.id,
                    name: Binding(get: { device.name }, set: { v in devices.update(device.id) { $0.name = v } }),
                    placeholder: device.guess ?? "Robot", connected: devices.isConnected(device.id),
                    testing: devices.isProbing, progress: probeProgress, result: probeResult, resultIsError: probeError,
                    found: device.found, onTest: { Task { await devices.test(device.id) } })
                RobotSetupView(
                    robotKinds: lerobot.robotKinds.map(\.type), teleopKinds: lerobot.teleopKinds.map(\.type),
                    models: (RobotQueries.bundled() + RobotQueries.imported()).map { ($0.id, $0.name) },
                    robotType: Binding(get: { device.robotKind }, set: { v in devices.update(device.id) { $0.robotType = v } }),
                    teleopType: Binding(get: { device.teleopKind }, set: { v in devices.update(device.id) { $0.teleopType = v } }),
                    modelID: Binding(get: { device.model ?? "" }, set: { v in devices.update(device.id) { $0.modelID = v } }),
                    followers: lerobot.followers(device), leaders: lerobot.leaders(device),
                    otherPorts: devices.connectedPorts.filter { $0 != device.id }, cameras: lerobot.cameras,
                    followerID: bindDevice(\.followerID), leaderPort: bindDevice(\.leaderPort), leaderID: bindDevice(\.leaderID),
                    cameraIndex: Binding(get: { lerobot.mainCamera(device) }, set: { i in
                        devices.update(device.id) { d in
                            d.cameraIndex = i
                            d.cameraName = lerobot.cameras.first { $0.index == i }?.name
                            d.extraCameraNames = d.extraNames.filter { $0 != d.cameraName }
                        }
                    }),
                    extraCameras: Binding(get: { device.extraNames }, set: { v in devices.update(device.id) { $0.extraCameraNames = v } }),
                    snapshot: snapshot,
                    onSnapshot: { Task { if let i = lerobot.mainCamera(device) { snapshot = await lerobot.snapshot(i) } } },
                    onRefreshCameras: { lerobot.refreshCameras() })
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction) }
                .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 620)
        .task { lerobot.refreshCameras() }
    }

    /// «Cameras and arm…» del paso 3: cada cámara que el modelo espera ↔ una cámara conectada.
    /// La primera es la principal; las demás son las extra, en orden.
    private func runSetupSheet(_ job: TrainJob) -> some View {
        let names = TrainQueries.cameras(job)
        return RunSetupView(
            modelCameras: names.isEmpty ? ["front"] : names, cameras: lerobot.cameras, followers: lerobot.followers(device),
            followerID: bindDevice(\.followerID),
            slots: Binding(get: { [lerobot.mainCamera(device)] + lerobot.extraCameras(device).map(\.index) }, set: { slots in
                let picked = slots.map { i in i.flatMap { i in lerobot.cameras.first { $0.index == i }?.name } }
                devices.update(device.id) { d in
                    if let first = slots.first, let main = first {
                        d.cameraIndex = main
                        d.cameraName = picked[0]
                    }
                    let extras = picked.dropFirst().compactMap { $0 }.filter { $0 != d.cameraName }
                    d.extraCameraNames = extras + d.extraNames.filter { !extras.contains($0) && $0 != d.cameraName && !lerobot.cameras.map(\.name).contains($0) }
                }
            }),
            previews: previews,
            onPreview: { i in Task { if let data = await lerobot.snapshot(i) { previews[i] = data } } },
            onRefreshCameras: { lerobot.refreshCameras() },
            onDone: { runSetupJob = nil })
            .task { lerobot.refreshCameras() }
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

    /// Abre la revisión previa y la corre.
    private func check(_ action: Action) {
        preflightFor = action
        checks = []
        checking = true
        Task {
            checks = await lerobot.preflight(
                device, withLeader: action == .record || action == .teleop, withCamera: action != .teleop,
                withExtras: action == .live || action == .run,
                roles: action == .run ? runTarget.map(TrainQueries.cameras) ?? [] : [])
            checking = false
        }
    }

    /// El modelo que se va a probar: el elegido en el resumen o el de la tarea abierta.
    private var runTarget: TrainJob? {
        if let name = runJob { return training.jobs.first { $0.name == name } }
        return tasks.selected(for: device.id).flatMap(trainingJob)
    }

    private var preflightTitle: String {
        switch preflightFor {
        case .record: "Before recording"
        case .live: "Before connecting"
        case .teleop: "Before moving with the leader"
        default: "Before running"
        }
    }

    private func confirmButtonTitle(_ action: Action) -> String {
        switch action {
        case .record: "Start recording"
        case .live: "Connect"
        case .teleop: "Move"
        case .run: "Run on the robot"
        }
    }

    private func run(_ action: Action?) async {
        // «Probar» desde el resumen: un modelo concreto, aunque no haya una tarea abierta.
        if action == .run, let name = runJob, let job = training.jobs.first(where: { $0.name == name }) {
            runJob = nil
            let task = tasks.tasks.first { name == $0.trainName || name.hasPrefix($0.trainName + "_") }
            await lerobot.runPolicy(device, modelPath: job.modelPath, task: task?.title ?? job.dataset, seconds: task?.runSeconds ?? 60)
            return
        }
        if action == .live { await live.start(device); return }
        guard let task = tasks.selected(for: device.id) else {
            if action == .teleop { await lerobot.teleoperate(device) }
            return
        }
        switch action {
        case .live: await live.start(device)
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
            let followers = lerobot.followers(d), leaders = lerobot.leaders(d)
            if d.followerID == nil, followers.count == 1 { d.followerID = followers[0] }
            if d.leaderID == nil, d.leaderPort != nil, leaders.count == 1 { d.leaderID = leaders[0] }
            // La cámara se recuerda por nombre (los números cambian al enchufar otra).
            if d.cameraName == nil, let i = d.cameraIndex { d.cameraName = lerobot.cameras.first { $0.index == i }?.name }
            if d.cameraIndex == nil {
                let external = lerobot.cameras.first(where: \.external)
                d.cameraIndex = (external ?? lerobot.cameras.first)?.index
                d.cameraName = (external ?? lerobot.cameras.first)?.name
            }
        }
    }

    // MARK: - Estado

    private var deviceName: String { device.name.isEmpty ? (device.guess ?? "Robot") : device.name }

    private var openTask: TeachTask? {
        guard lerobot.session?.active != true || lerobot.session?.kind == "teleop" else { return nil }
        return tasks.selected(for: device.id)
    }

    private func demosRecorded(_ task: TeachTask) -> Int { status(task).demos }

    private func trainingJob(_ task: TeachTask) -> TrainJob? { status(task).job }

    private func status(_ task: TeachTask) -> TaskStatus {
        TaskStatus.of(task, datasets: datasets.local, jobs: training.jobs, progress: training.progress)
    }

    /// Cuánto tardaría, medido en los entrenamientos de esta Mac con el mismo modelo (segundos por paso del
    /// último que avanzó). Sin ninguno medido no se adivina: nil.
    private func eta(_ task: TeachTask) -> String? {
        let measured = training.jobs.reversed().lazy.compactMap { job -> Double? in
            guard job.policy == task.policy, let p = training.progress[job.name], p.step > 0,
                  let seconds = p.elapsed.flatMap(Units.seconds) else { return nil }
            return seconds / Double(p.step)
        }.first
        guard let perStep = measured else { return nil }
        return "About " + Units.duration(perStep * Double(task.steps))
    }

    private func policyName(_ id: String) -> String { PolicyOption.all.first { $0.id == id }?.name ?? id.uppercased() }

    private var notice: String? { training.message ?? lerobot.error ?? lerobotStatusError }

    private var lerobotStatusError: String? {
        if case .failed(let reason) = lerobot.status { return "LeRobot didn’t start: \(reason)" }
        return nil
    }

    private var subtitle: String {
        if lerobot.status == .starting { return "Loading LeRobot…" }
        if lerobot.session?.active == true && lerobot.session?.kind == "teleop" { return "Moving with the leader" }
        return devices.isConnected(device.id) ? (device.leaderPort == nil ? "Plugged in" : "Plugged in · with leader") : "Unplugged"
    }

    // MARK: - Confirmaciones

    private var confirmTitle: String {
        switch confirm {
        case .teleop: "Move with the leader?"
        case .record: "Start recording?"
        case .run: "Let it do it on its own?"
        case .live: "Connect live?"
        case nil: ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .teleop: "Move"
        case .record: "Record"
        case .run: "Run on the robot"
        case .live: "Connect"
        case nil: "OK"
        }
    }

    private var confirmMessage: String { confirm.map(message) ?? "" }

    private func message(_ action: Action) -> String {
        switch action {
        case .live:
            "The arm holds its pose."
        case .teleop, .record:
            "The follower jumps to the leader’s pose. Keep them close."
        case .run:
            "It moves on its own. Clear the table. Esc stops it."
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
        return device.found.isEmpty ? "No motors responded (\(when)). Check that its power supply is on."
                                    : "Connected: \(device.found.count) motors responded (\(when))."
    }

    private var probeError: Bool { if case .failed = devices.probe { true } else { false } }
}
