import SwiftUI

/// Un robot real (SO-101). Lo principal: enseñarle una tarea en tres pasos (demostraciones, entrenar,
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
    @State private var confirm: Action?
    @State private var showingSettings = false
    @State private var showingHub = false
    @State private var snapshot: Data?
    @State private var deleting: DatasetInfo?
    // Revisión previa (grabar o probar): cada pieza, sin mover nada.
    @State private var preflightFor: Action?
    @State private var checks: [PreflightCheck] = []
    @State private var checkPicture: Data?
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
            .sheet(isPresented: Binding(get: { training.watched != nil }, set: { if !$0 { training.watch(nil) } })) {
                liveTraining
            }
            .sheet(isPresented: Binding(get: { preflightFor != nil }, set: { if !$0 { preflightFor = nil } })) {
                PreflightView(
                    title: preflightFor == .record ? "Before recording" : preflightFor == .live ? "Before connecting" : "Before running",
                    checks: checks, picture: checkPicture, checking: checking,
                    warning: preflightFor.map(message) ?? "",
                    startTitle: preflightFor == .record ? "Start recording" : preflightFor == .live ? "Connect" : "Run on the robot",
                    onRetry: { if let a = preflightFor { check(a) } },
                    onStart: {
                        let action = preflightFor
                        preflightFor = nil
                        Task { await run(action) }
                    },
                    onCancel: { preflightFor = nil },
                    onFix: { preflightFor = nil; showingSettings = true },
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
                     ? "This deletes the copy on this Mac. It stays on Hugging Face and can be downloaded again."
                     : "This deletes its \(deleting?.episodes ?? 0) demonstrations from this Mac. This can’t be undone. Models already trained are kept.")
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
            canRecord: device.canRecord, canRun: device.canRunPolicy, busy: lerobot.isBusy, notice: notice)
        let actions = TaskPageActions(
            onRecord: { check(.record) },
            onHub: openHub,
            onUseOwn: { tasks.update(task.id) { $0.hubDataset = false; $0.dataset = Naming.slug($0.title) } },
            onTrain: { startTraining(task) },
            onStopTraining: { if let job = s.job { training.stop(job) } },
            onWatchTraining: s.job.map { job in { training.watch(job.name) } },
            onRun: { runJob = nil; check(.run) },
            onFixSetup: { showingSettings = true },
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
            .help("Teach it tasks, or control it now with chat and the controls")
        }
        if live.isLive {
            ToolbarItem(placement: .primaryAction) {
                Button { liveChat?.stop(); live.stop() } label: { Label("Release", systemImage: "stop.fill") }
                    .labelStyle(.titleAndIcon)
                    .disabled(live.isReturning)
                    .help("Slowly returns to its starting pose and releases the motors")
            }
        }
        if device.leaderPort != nil && !live.isLive && mode == .teach { ToolbarItem(placement: .primaryAction) {
            if lerobot.session?.active == true && lerobot.session?.kind == "teleop" {
                Button { lerobot.stop() } label: { Label("Stop moving", systemImage: "stop.fill") }
                    .help("Releases the follower’s motors")
            } else {
                Button { confirm = .teleop } label: { Label("Move with the leader", systemImage: "hand.raised") }
                    .disabled(!device.canTeleoperate || lerobot.isBusy)
                    .help(device.canTeleoperate ? "This robot copies its leader. Nothing is recorded." : "Choose the leader’s calibration in Robot settings")
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
                    placeholder: device.guess ?? "SO-101", connected: devices.isConnected(device.id),
                    testing: devices.isProbing, progress: probeProgress, result: probeResult, resultIsError: probeError,
                    found: device.found, onTest: { Task { await devices.test(device.id) } })
                RobotSetupView(
                    followers: lerobot.calibrations.followers, leaders: lerobot.calibrations.leaders,
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
                    onSnapshot: { Task { if let i = lerobot.mainCamera(device) { snapshot = await lerobot.snapshot(i) } } })
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done") { showingSettings = false }.keyboardShortcut(.defaultAction) }
                .padding(Theme.Space.l)
        }
        .frame(width: 560, height: 620)
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
        checkPicture = nil
        checking = true
        Task {
            let r = await lerobot.preflight(device, withLeader: action == .record, withExtras: action == .live)
            checks = r.checks
            checkPicture = r.picture
            checking = false
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
            if d.followerID == nil, lerobot.calibrations.followers.count == 1 { d.followerID = lerobot.calibrations.followers[0] }
            if d.leaderID == nil, d.leaderPort != nil, lerobot.calibrations.leaders.count == 1 { d.leaderID = lerobot.calibrations.leaders[0] }
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

    private var deviceName: String { device.name.isEmpty ? (device.guess ?? "SO-101") : device.name }

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
        return hours < 1 ? "under 1 h" : "about \(Int(hours.rounded())) h"
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
            "The arm will hold its pose. It only moves with the controls or when you approve what the AI suggests."
        case .teleop, .record:
            "The follower will copy the leader as soon as it connects. Put the leader in a pose similar to the follower’s, with both power supplies on."
        case .run:
            "The robot will move on its own. Clear the table and stay near the power supply; Esc stops it."
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
