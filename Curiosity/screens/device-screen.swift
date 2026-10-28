import SwiftUI

/// Un robot real (SO-101): configurarlo, teleoperarlo con el leader, grabar datasets, entrenar modelos
/// (con datos propios o de Hugging Face) y probarlos. Todo lo que mueve el robot pide confirmación.
struct DeviceScreen: View {
    let device: Device
    @Environment(UseDevices.self) private var devices
    @Environment(UseLeRobot.self) private var lerobot
    @Environment(UseDatasets.self) private var datasets
    @Environment(UseTraining.self) private var training

    enum Tab: String, CaseIterable, Identifiable {
        case setup = "Configurar", teleop = "Teleoperar", record = "Grabar", data = "Datos", train = "Entrenar", run = "Probar"
        var id: String { rawValue }
    }
    @AppStorage("device.tab") private var tab: Tab = .setup
    @State private var snapshot: Data?
    @State private var confirm: Tab?

    // Formularios
    @State private var dataset = ""
    @State private var task = ""
    @State private var episodes = 50
    @State private var episodeSeconds = 60.0
    @State private var resetSeconds = 10.0
    @State private var trainName = ""
    @State private var trainDataset = ""
    @State private var policy = PolicyOption.all[0]
    @State private var steps = 20_000
    @State private var batchSize = 8
    @State private var modelPath = ""
    @State private var runTask = ""
    @State private var runSeconds = 60.0

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sección", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)
            .padding(.top, Theme.Space.m)

            if case .failed(let reason) = lerobot.status {
                Label("LeRobot no arrancó: \(reason)", systemImage: IconName.warning.rawValue)
                    .font(.callout).foregroundStyle(Theme.red).padding(.top, Theme.Space.s)
            } else if lerobot.status == .starting {
                HStack { ProgressView().controlSize(.small); Text("Cargando LeRobot…").foregroundStyle(Theme.muted) }
                    .font(.callout).padding(.top, Theme.Space.s)
            }
            if let e = lerobot.error { Text(e).font(.callout).foregroundStyle(Theme.red).padding(.top, Theme.Space.xs) }

            content.frame(maxWidth: 720, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(title)
        .navigationSubtitle("\(devices.isConnected(device.id) ? "Enchufado" : "Desenchufado") · \(device.portName)")
        .task { await lerobot.start() }
        .task(id: tab) {
            if tab == .data || tab == .train { await datasets.load() }
            if tab == .data, datasets.hub.isEmpty { await datasets.search() }
        }
        .onChange(of: device.id) { devices.resetProbe(); snapshot = nil }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirmButton) { Task { await startConfirmed() } }
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .setup:
            Form {
                HardwareTestView(
                    port: device.id,
                    name: Binding(get: { device.name }, set: { v in devices.update(device.id) { $0.name = v } }),
                    placeholder: device.guess ?? "SO-101",
                    connected: devices.isConnected(device.id),
                    testing: devices.isProbing, progress: progress, result: result, resultIsError: isError, found: device.found,
                    onTest: { Task { await devices.test(device.id) } })
                RobotSetupView(
                    followers: lerobot.calibrations.followers, leaders: lerobot.calibrations.leaders,
                    otherPorts: devices.connectedPorts.filter { $0 != device.id }, cameras: lerobot.cameras,
                    followerID: bind(\.followerID), leaderPort: bind(\.leaderPort), leaderID: bind(\.leaderID),
                    cameraIndex: bind(\.cameraIndex), snapshot: snapshot,
                    onSnapshot: { Task { if let i = device.cameraIndex { snapshot = await lerobot.snapshot(i) } } })
            }
            .formStyle(.grouped)
        case .teleop:
            TeleopPanel(session: lerobot.session?.kind == "teleop" ? lerobot.session : nil,
                        ready: device.canTeleoperate && !lerobot.isBusy || lerobot.session?.kind == "teleop",
                        onStart: { confirm = .teleop }, onStop: lerobot.stop)
        case .record:
            RecordPanel(dataset: $dataset, task: $task, episodes: $episodes, episodeSeconds: $episodeSeconds, resetSeconds: $resetSeconds,
                        session: lerobot.session, frame: lerobot.frame, ready: device.canRecord && !lerobot.isBusy,
                        onStart: { confirm = .record }, onNext: lerobot.next, onRedo: lerobot.redo, onStop: lerobot.stop)
        case .data:
            DatasetsPanel(local: datasets.local, hub: datasets.hub, query: Bindable(datasets).query, searching: datasets.searching,
                          message: datasets.message, canPush: lerobot.env?.hubUser != nil,
                          onSearch: { Task { await datasets.search() } },
                          onTrain: { repo, _ in trainDataset = repo; if trainName.isEmpty { trainName = suggestedName(repo) }; tab = .train },
                          onPush: { d in Task { await datasets.push(d, private: true) } },
                          onDelete: { d in Task { await datasets.delete(d) } })
        case .train:
            TrainPanel(name: $trainName, dataset: $trainDataset, policy: $policy, steps: $steps, batchSize: $batchSize,
                       datasetChoices: datasetChoices, smolvla: lerobot.env?.smolvla ?? false,
                       jobs: training.jobs, progress: training.progress, message: training.message,
                       onStart: startTraining, onStop: training.stop,
                       onTry: { job in modelPath = job.modelPath; tab = .run }, onRemove: training.remove)
        case .run:
            RolloutPanel(models: training.finished, modelPath: $modelPath, task: $runTask, seconds: $runSeconds,
                         session: lerobot.session, frame: lerobot.frame, ready: device.canRunPolicy && !lerobot.isBusy,
                         onStart: { confirm = .run }, onStop: lerobot.stop)
        }
    }

    // MARK: - Acciones

    private func startConfirmed() async {
        switch confirm {
        case .teleop: await lerobot.teleoperate(device)
        case .record:
            guard AppPaths.isValidName(dataset) else { return }
            await lerobot.record(device, dataset: dataset, task: task, episodes: episodes,
                                 episodeSeconds: episodeSeconds, resetSeconds: resetSeconds)
        case .run: await lerobot.runPolicy(device, modelPath: modelPath, task: runTask, seconds: runSeconds)
        default: break
        }
        confirm = nil
    }

    private func startTraining() {
        let root = datasets.local.first { $0.repoID == trainDataset && $0.source == "local" }?.root
        training.start(name: trainName, dataset: trainDataset, datasetRoot: root, policy: policy, steps: steps, batchSize: batchSize)
    }

    private var datasetChoices: [String] {
        var ids = datasets.local.map(\.repoID) + datasets.hub.map(\.id)
        if !trainDataset.isEmpty && !ids.contains(trainDataset) { ids.insert(trainDataset, at: 0) }
        return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
    }

    private func suggestedName(_ repo: String) -> String {
        let base = repo.split(separator: "/").last.map(String.init) ?? "modelo"
        return "\(policy.id)_\(base)".replacingOccurrences(of: ".", with: "_").prefix(60).description
    }

    private func bind<T>(_ key: WritableKeyPath<Device, T>) -> Binding<T> {
        Binding(get: { device[keyPath: key] }, set: { v in devices.update(device.id) { $0[keyPath: key] = v } })
    }

    // MARK: - Textos

    private var title: String { device.name.isEmpty ? (device.guess ?? "SO-101") : device.name }

    private var confirmTitle: String {
        switch confirm {
        case .teleop: "¿Teleoperar?"
        case .record: "¿Empezar a grabar?"
        case .run: "¿Dejar que el robot use el modelo?"
        default: ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .teleop: "Teleoperar"
        case .record: "Grabar"
        case .run: "Probar en el robot"
        default: "Aceptar"
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .teleop, .record:
            "El follower va a copiar al leader en cuanto se conecte. Deja el leader en una pose parecida a la del follower, con las fuentes encendidas (follower 12 V, leader 5 V). Al terminar, el follower suelta los motores."
        case .run:
            "El robot se va a mover solo durante \(Int(runSeconds)) s. Despeja la mesa y quédate cerca de la fuente; Esc lo detiene."
        default: ""
        }
    }

    // MARK: - Prueba de conexión

    private var progress: Double { if case .running(let p) = devices.probe { p } else { 0 } }

    private var result: String? {
        if case .failed(let m) = devices.probe { return m }
        guard let at = device.probedAt else { return nil }
        let when = at.formatted(date: .omitted, time: .shortened)
        return device.found.isEmpty ? "El puerto abrió, pero no respondió ningún motor (\(when)). Revisa que el brazo tenga su fuente encendida."
                                    : "Conexión correcta: \(device.found.count) motores respondieron (\(when))."
    }

    private var isError: Bool { if case .failed = devices.probe { true } else { false } }
}
