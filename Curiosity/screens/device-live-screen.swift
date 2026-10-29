import SwiftUI

extension EnvironmentValues {
    /// La conversación con el robot real (la del simulador es `UseChat` en el entorno).
    @Entry var liveChat: UseChat?
}

/// El robot real en vivo, como el simulador: la cámara a todo lo ancho y, flotando, el chat y el control.
/// Antes de conectar, una sola acción; conectar pasa por la revisión previa (la hace DeviceScreen).
struct DeviceLiveScreen: View {
    let device: Device
    let robotName: String
    let onConnect: () -> Void
    @Environment(UseLiveRobot.self) private var live
    @Environment(UseSettings.self) private var settings
    @Environment(UseLeRobot.self) private var lerobot
    @Environment(UseDevices.self) private var devices
    @Environment(\.liveChat) private var chat
    @Environment(UseKnowledge.self) private var knowledge
    @Environment(UseDatasets.self) private var datasets
    @Environment(UseTraining.self) private var training
    @State private var showingHub = false
    @Environment(\.openSettings) private var openSettings

    enum PanelTab: String, Hashable { case chat, control, arm, model, knowledge, notes }
    @AppStorage("live.tab") private var tab: PanelTab = .chat
    /// Cuánto ocupan las vistas chicas (se cambia arrastrando el divisor y se recuerda).
    @AppStorage("live.tileSplit") private var tileSplit: Double = Double(TileLayout.defaultSplit)
    @State private var focused = 0
    @State private var robotNotes = UseRobotNotes()
    // El modelo de órdenes: cuál, y la última orden de prueba (se recuerdan entre sesiones).
    @AppStorage("live.skillPath") private var skillPath = ""
    @AppStorage("live.skillInstruction") private var skillInstruction = ""
    @AppStorage("live.skillSeconds") private var skillSeconds = 15.0
    @AppStorage("live.skillRecent") private var skillRecent = ""

    var body: some View {
        Group {
            if live.isLive {
                stage
            } else {
                start
            }
        }
        .toolbar {
            if live.isLive {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("Live cameras") {
                            ForEach(lerobot.cameras) { c in
                                if c.index == lerobot.mainCamera(device) {
                                    Text("\(c.name) · main")
                                } else {
                                    Toggle(c.name, isOn: extraBinding(c.name))
                                }
                            }
                        }
                        Button("Search again", systemImage: "arrow.clockwise") { lerobot.refreshCameras() }
                    } label: {
                        Label("Cameras", systemImage: "video.badge.plus")
                    }
                    .help("Cameras")
                }
            }
        }
        .onChange(of: device) { live.update(device) }
        .sheet(isPresented: $showingHub) {
            @Bindable var datasets = datasets
            HubPickerView(results: datasets.hub, query: $datasets.query, searching: datasets.searching,
                          onSearch: { Task { await datasets.search() } },
                          onPick: { d in showingHub = false; study(d.id, root: nil) },
                          onClose: { showingHub = false },
                          detail: "")
        }
        .task(id: device.id) {
            let key = "device-" + device.id
            if chat?.robotID != key { chat?.reset(robotName: robotName, robotID: key) }
        }
    }

    /// Las vistas en vivo: cada cámara y el modelo 3D que copia al robot. Un clic destaca una.
    private var tiles: some View {
        let cams = live.cameras
        // La forma de cada cámara sale de su propia imagen (16:9, 4:3…); el modelo 3D, 4:3.
        let camAspects: [CGFloat] = cams.map { cam in
            guard let frame = cam.frame, let size = NSImage(data: frame)?.size, size.height > 0 else { return 16 / 9 }
            return size.width / size.height
        }
        let aspects: [CGFloat] = camAspects + [4 / 3]
        return GeometryReader { geo in
            let arrangement = TileLayout.arrange(aspects, main: min(focused, aspects.count - 1), size: geo.size, gap: 10, split: tileSplit)
            ZStack(alignment: .topLeading) {
        TileLayout(focused: focused, aspects: aspects, split: tileSplit) {
            ForEach(Array(cams.enumerated()), id: \.element.key) { i, cam in
                Tile(title: cam.name, focused: i == focused, onTap: { focused = i }) {
                    if let frame = cam.frame, let image = NSImage(data: frame) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ProgressView()
                    }
                }
            }
            Tile(title: "3D model", focused: focused == cams.count, onTap: { focused = cams.count }) {
                SimStage(engine: live.twin)
            }
        }
                TileDivider(arrangement: arrangement, size: geo.size, split: $tileSplit)
            }
            .coordinateSpace(.named("tiles"))
        }
        .overlay(alignment: .bottomLeading) {
            Label(live.isReturning ? "Returning to its pose…" : live.isReady ? "Live" : "Connecting…",
                  systemImage: live.isReady ? "circle.fill" : "circle.dotted")
                .font(.caption.weight(.medium))
                .foregroundStyle(live.isReady ? Theme.ink : Theme.muted)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(Theme.Space.m)
                .allowsHitTesting(false)
        }
    }

    private var start: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.muted)
            VStack(spacing: Theme.Space.s) {
                Text("Control it live").font(.title.weight(.semibold))
            }
            Button("Connect", action: onConnect)
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!device.canRunPolicy || lerobot.isBusy)
            if !device.canRunPolicy {
                Text("Set up the follower and camera first.").font(.callout).foregroundStyle(Theme.muted)
            }
            cameraPicker
            if let error = lerobot.error {
                Text(error).font(.callout).foregroundStyle(Theme.red).multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Prueba a mano: la persona escribió la orden y apretó «Run» (eso es la aprobación).
    private func runSkill() {
        let text = skillInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let recent = [text] + skillRecent.split(separator: "\n").map(String.init).filter { $0 != text }
        skillRecent = recent.prefix(6).joined(separator: "\n")
        Task { try? await live.runSkill(text, seconds: skillSeconds) }
    }

    /// Guarda la calibración de la cámara en el robot (queda para las próximas veces).
    private func saveCalibration() {
        guard let name = live.calibrating, let fit = live.calibrationFit else { return }
        devices.update(device.id) { $0.cameraCalibrations = ($0.cameraCalibrations ?? [:]).merging([name: fit]) { $1 } }
        var updated = device
        updated.cameraCalibrations = (device.cameraCalibrations ?? [:]).merging([name: fit]) { $1 }
        live.update(updated)
        live.cancelCalibration()
    }

    private func study(_ repoID: String, root: String?) {
        Task { await knowledge.study(repoID: repoID, root: root, robotType: device.robotKind, followerID: device.followerID) }
    }

    /// Activar o quitar una cámara extra; si ya está en vivo, se aplica sin desconectar.
    private func extraBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { device.extraNames.contains(name) }, set: { on in
            var updated = device
            updated.extraCameraNames = on ? device.extraNames + [name] : device.extraNames.filter { $0 != name }
            devices.update(device.id) { $0.extraCameraNames = updated.extraCameraNames }
            if live.isLive { live.setExtraCameras(updated) }
        })
    }

    /// Qué cámaras se ven en vivo: la principal (la de grabar) y las que actives.
    private var cameraPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text("Cameras").font(.headline)
                Spacer()
                Button(action: { lerobot.refreshCameras() }) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Search for cameras again")
            }
            ForEach(lerobot.cameras) { c in
                if c.index == lerobot.mainCamera(device) {
                    Label("\(c.name) · main", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.muted)
                } else {
                    Toggle(c.name, isOn: extraBinding(c.name))
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 360, alignment: .leading)
        .background(Theme.fill.opacity(0.5), in: .rect(cornerRadius: 14))
    }

    private var stage: some View {
        ZStack {
            // Las cámaras y el modelo 3D, cada uno en su contenedor, en lo que deja libre el panel.
            tiles
                .padding(Theme.Space.xl)
                .padding(.trailing, Theme.chatWidth + Theme.Space.m)
        }
        .overlay(alignment: .trailing) {
            FloatingPanel(tabs: [(.chat, "Chat"), (.control, "Control"), (.arm, "Arm"), (.model, "Model"), (.knowledge, "Knowledge"), (.notes, "Notes")], selection: $tab) {
                switch tab {
                case .chat:
                    if let chat {
                        ChatView(items: chat.items, isRunning: chat.isRunning, error: chat.error,
                                 hasKey: settings.hasAnthropicKey, robotName: robotName,
                                 suggestions: ["What do you see on the table?", "Open the gripper a little", "Wave by moving the wrist"],
                                 conversations: chat.conversations, currentID: chat.conversationID,
                                 onSend: chat.send, onStop: chat.stop, onOpenSettings: { openSettings() },
                                 onNew: { chat.reset(robotName: robotName, robotID: "device-" + device.id) },
                                 onOpenConversation: chat.open, onDeleteConversation: chat.delete,
                                 onApprove: chat.approve, onReject: chat.reject)
                    }
                case .control:
                    LiveControls(joints: lerobot.session?.jointNames ?? [], positions: live.joints, targets: live.targets,
                                 limits: live.limits, onChange: live.setTarget, onHome: live.home)
                        .disabled(!live.isReady)
                case .arm:
                    ArmPanel(cameras: live.cameras.map { .init(name: $0.name, frame: $0.frame, fit: live.calibration($0.name)) },
                             calibrating: live.calibrating, marked: live.calibrationPairs.map(\.pixel),
                             pointCount: UseLiveRobot.calibrationCount, fit: live.calibrationFit,
                             busy: live.armBusy, error: live.armError,
                             onStart: { name in Task { await live.startCalibration(name) } },
                             onMove: { i in Task { await live.moveToCalibrationPoint(i) } },
                             onMark: { x, y in Task { await live.markCalibration(x: x, y: y) } },
                             onUndo: live.undoCalibrationPoint, onSave: saveCalibration, onCancel: live.cancelCalibration)
                        .disabled(!live.isReady)
                case .model:
                    @Bindable var live = live
                    SkillPanel(trained: training.finished.map { ($0.name, $0.modelPath) }, path: $skillPath,
                               loaded: live.skillModel, loading: live.skillLoading, error: live.skillError,
                               forAI: $live.skillForAI, instruction: $skillInstruction, seconds: $skillSeconds,
                               running: live.skillRun, last: live.skillLast,
                               recent: skillRecent.split(separator: "\n").map(String.init),
                               onLoad: { Task { await live.loadSkill(skillPath) } },
                               onRun: runSkill, onStop: live.stopSkill)
                        .disabled(!live.isReady)
                case .notes:
                    RobotNotesPanel(facts: live.chatRobotFacts, notes: robotNotes.notes, learned: robotNotes.learned,
                                    onNotes: robotNotes.setNotes, onRemoveLesson: robotNotes.removeLesson,
                                    onReveal: robotNotes.reveal)
                        .task(id: device.id) {
                            robotNotes.open("device-" + device.id)
                            chat?.onRemember = { [robotNotes] in robotNotes.reload() }
                        }
                case .knowledge:
                    KnowledgePanel(packages: knowledge.packages, activeID: knowledge.activeID, studying: knowledge.studying,
                                   error: knowledge.error, localDatasets: datasets.local.filter { $0.source == "local" },
                                   onStudy: { d in study(d.repoID, root: d.root) },
                                   onSearchHub: { showingHub = true; Task { if datasets.hub.isEmpty { await datasets.search() } } },
                                   onActivate: { knowledge.activeID = $0 },
                                   onRemove: knowledge.remove)
                        .task { await datasets.load() }
                }
            }
            .frame(width: Theme.chatWidth)
            .padding([.horizontal, .bottom], Theme.Space.m)
            .padding(.top, Theme.Space.xs)
        }
    }
}
