import SwiftUI

/// El espacio de trabajo de un robot: escenario 3D a todo lo ancho y, flotando encima, el panel con
/// el chat, el control manual y la escena. Los controles de la simulación van en la toolbar.
struct WorkspaceScreen: View {
    let robot: Robot
    @Environment(UseSimulation.self) private var simulation
    @Environment(UseChat.self) private var chat
    @Environment(UseSettings.self) private var settings
    @Environment(UseRobots.self) private var robots
    @Environment(\.openSettings) private var openSettings
    @Environment(UseSimRecording.self) private var recording
    @Environment(UseDevices.self) private var devices
    @State private var showingRecord = false

    enum PanelTab: String, Hashable { case chat, control, simulation, scene }
    /// Se recuerda la última pestaña.
    @AppStorage("panel.tab") private var tab: PanelTab = .chat
    @State private var panelVisible = true
    @State private var showingModel = false

    private static let speeds: [Double] = [0.25, 0.5, 1, 2]

    var body: some View {
        @Bindable var simulation = simulation
        ZStack(alignment: .bottomLeading) {
            // El escenario llega hasta el borde de la ventana, también debajo de la toolbar.
            ZStack {
                Theme.stage
                SimStage(engine: simulation.engine, rightInset: panelVisible ? Theme.chatWidth + Theme.Space.m : 0)
            }
            .ignoresSafeArea()

            if let error = simulation.error {
                StageMessage(text: error, isError: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loading = simulation.loadingText {
                StageMessage(text: loading, isError: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack(spacing: Theme.Space.s) {
                SimHUD(time: simulation.state.time, realTimeFactor: simulation.state.realTimeFactor,
                       contacts: simulation.state.contacts, paused: simulation.state.paused)
                if let notice = simulation.notice {
                    Text(notice).font(.caption.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .animation(.snappy, value: simulation.notice)
            .padding(Theme.Space.xl)

            if let s = recording.session, s.active {
                SimRecordBar(session: s, onNext: recording.next, onRedo: recording.redo, onStop: recording.stop)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.trailing, panelVisible ? Theme.chatWidth + Theme.Space.m : 0)
                    .padding(.bottom, Theme.Space.xl)
            }
        }
        // El panel sí respeta la toolbar: empieza debajo de ella.
        .overlay(alignment: .trailing) {
            if panelVisible {
                FloatingPanel(tabs: [(.chat, "Chat"), (.control, "Control"), (.simulation, "Simulation"), (.scene, "Scene")],
                              selection: $tab) {
                    switch tab {
                    case .chat:
                        ChatView(items: chat.items, isRunning: chat.isRunning, error: chat.error,
                                 hasKey: settings.hasAnthropicKey, robotName: robot.name,
                                 suggestions: suggestions,
                                 conversations: chat.conversations, currentID: chat.conversationID,
                                 onSend: chat.send, onStop: chat.stop, onOpenSettings: { openSettings() },
                                 onNew: { chat.reset(robotName: robot.name, robotID: robot.id) },
                                 onOpenConversation: chat.open, onDeleteConversation: chat.delete)
                    case .control:
                        JointControls(joints: simulation.model?.joints ?? [], states: simulation.state.joints,
                                      onChange: simulation.setTarget, onClear: simulation.clearControls,
                                      onReset: simulation.reset)
                    case .simulation:
                        SimulationPanel(state: simulation.state, model: simulation.model,
                                        physics: $simulation.physics, render: $simulation.render,
                                        keyframes: simulation.keyframes, speed: simulation.speed,
                                        onTogglePause: simulation.togglePause, onReset: simulation.reset,
                                        onReload: simulation.reload, onAlign: simulation.align,
                                        onCopyState: { Task { await simulation.copyState() } },
                                        onSpeed: simulation.setSpeed,
                                        onSaveKey: { Task { await simulation.saveKeyframe() } },
                                        onLoadKey: simulation.loadKeyframe, onDeleteKey: simulation.deleteKeyframe,
                                        onScreenshot: { Task { await simulation.screenshot() } },
                                        onShowModel: { showingModel = true })
                    case .scene:
                        SceneControls(objects: simulation.objects,
                                      onAdd: { o in Task { try? await simulation.addObject(o) } },
                                      onRemove: simulation.removeObject)
                    }
                }
                .frame(width: Theme.chatWidth)
                .padding([.horizontal, .bottom], Theme.Space.m)
                .padding(.top, Theme.Space.xs)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .navigationTitle(robot.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(isPresented: $showingRecord) {
            SimRecordSheet(leaders: devices.devices.filter(\.canTeleoperate),
                           onStart: { leader, task, episodes, seconds in
                               showingRecord = false
                               Task { await recording.start(leader: leader, task: task, episodes: episodes, seconds: seconds, reset: 5) }
                           },
                           onCancel: { showingRecord = false })
        }
        .sheet(isPresented: $showingModel) {
            ModelSheet(title: simulation.model?.name ?? robot.name, text: simulation.modelSummary)
        }
        .onAppear {
            open()
        }
        .onChange(of: robot.id) { open() }
    }

    private var subtitle: String {
        guard let m = simulation.model else { return "Loading…" }
        return "\(m.joints.count) joints · \(m.links.count) links"
    }

    /// Ideas para empezar, según lo que tiene el robot.
    private var suggestions: [String] {
        var out = ["What do you see in the scene?", "Wave hello with the arm"]
        if !(simulation.objects.isEmpty) { out.append("Push the red cube to the left") }
        if simulation.model?.joints.contains(where: { $0.name.lowercased().contains("grip") }) == true {
            out.append("Open and close the gripper")
        }
        return out
    }

    private func open() {
        let profile = robots.profile(for: robot)
        simulation.open(robot, profile: profile)
        chat.reset(robotName: robot.name, robotID: robot.id)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { simulation.togglePause() } label: {
                Label(simulation.state.paused ? "Resume" : "Pause",
                      systemImage: simulation.state.paused ? IconName.play.rawValue : IconName.pause.rawValue)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(simulation.state.paused ? "Resume (Space)" : "Pause (Space)")

            Button { simulation.step() } label: { Label("Step", systemImage: IconName.step.rawValue) }
                .disabled(!simulation.state.paused)
                .help("Step forward a few frames")

            Button { simulation.reset() } label: { Label("Reset", systemImage: IconName.reset.rawValue) }
                .keyboardShortcut("r", modifiers: .command)
                .help("Back to the home pose (⌘R)")

            Menu {
                Picker("Speed", selection: Binding(get: { simulation.speed }, set: simulation.setSpeed)) {
                    ForEach(Self.speeds, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Section("View") {
                    Button("3/4") { simulation.view("tres") }
                    Button("Front") { simulation.view("frente") }
                    Button("Side") { simulation.view("lado") }
                    Button("Top") { simulation.view("arriba") }
                }
                if let cams = simulation.model?.cameras, !cams.isEmpty {
                    Section("Robot camera") {
                        Picker("Camera", selection: Binding(get: { simulation.activeCamera ?? "" },
                                                           set: { simulation.showCamera($0.isEmpty ? nil : $0) })) {
                            Text("None").tag("")
                            ForEach(cams, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                }
            } label: {
                Label("View", systemImage: IconName.views.rawValue)
            }
            .help("Speed, view and cameras")
        }

        if recording.canRecord {
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button { showingRecord = true } label: { Label("Record with the leader", systemImage: "record.circle") }
                    .disabled(recording.isActive || devices.devices.allSatisfy { !$0.canTeleoperate })
                    .help(devices.devices.contains(where: \.canTeleoperate)
                          ? "Record demos by moving the simulated robot with your leader"
                          : "Connect your SO-101 and its leader to record in the simulation")
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup(placement: .primaryAction) {
            Button { chat.reset(robotName: robot.name, robotID: robot.id); tab = .chat } label: {
                Label("New conversation", systemImage: IconName.clear.rawValue)
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("New conversation (⌘N)")

            Button { withAnimation(.snappy) { panelVisible.toggle() } } label: {
                Label("Panel", systemImage: "sidebar.right")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .help("Show or hide the panel (⌥⌘0)")
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("Settings", systemImage: IconName.settings.rawValue)
            }
            .help("Settings: connect API keys and choose the model (⌘,)")
        }
    }
}
