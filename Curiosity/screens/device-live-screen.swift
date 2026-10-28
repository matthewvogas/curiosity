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
    @State private var showingHub = false
    @Environment(\.openSettings) private var openSettings

    enum PanelTab: String, Hashable { case chat, control, knowledge }
    @AppStorage("live.tab") private var tab: PanelTab = .chat
    @State private var focused = 0

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
                        Text("Not showing up? Connect it over USB in webcam mode.")
                    } label: {
                        Label("Cameras", systemImage: "video.badge.plus")
                    }
                    .help("Add or remove cameras without disconnecting the robot")
                }
            }
        }
        .task(id: live.isLive) {
            // Las cámaras que se enchufen aparecen solas en la lista.
            while !Task.isCancelled {
                lerobot.refreshCameras()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: device) { live.update(device) }
        .sheet(isPresented: $showingHub) {
            @Bindable var datasets = datasets
            HubPickerView(results: datasets.hub, query: $datasets.query, searching: datasets.searching,
                          onSearch: { Task { await datasets.search() } },
                          onPick: { d in showingHub = false; study(d.id, root: nil) },
                          onClose: { showingHub = false },
                          detail: "Demonstrations from an SO-100/101. The AI studies a few (only those are downloaded) and writes down how the task is done.")
        }
        .task(id: device.id) {
            let key = "device-" + device.id
            if chat?.robotID != key { chat?.reset(robotName: robotName, robotID: key) }
        }
    }

    /// Las vistas en vivo: cada cámara y el modelo 3D que copia al robot. Un clic destaca una.
    private var tiles: some View {
        let cams = live.cameras
        return TileLayout(focused: focused) {
            ForEach(Array(cams.enumerated()), id: \.element.key) { i, cam in
                Tile(title: cam.name, focused: i == focused, onTap: { focused = i }) {
                    if let frame = cam.frame, let image = NSImage(data: frame) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
            }
            Tile(title: "3D model", focused: focused == cams.count, onTap: { focused = cams.count }) {
                SimStage(engine: live.twin)
            }
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
                Text("Talk to it or move it with the controls while watching through its camera.\nWhen connected it holds its pose; when released it returns to it and relaxes.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            }
            Button("Connect", action: onConnect)
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!device.canRunPolicy || lerobot.isBusy)
            if !device.canRunPolicy {
                Text("Choose the follower calibration and the camera in Robot settings.").font(.callout).foregroundStyle(Theme.muted)
            }
            cameraPicker
            if let error = lerobot.error {
                Text(error).font(.callout).foregroundStyle(Theme.red).multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func study(_ repoID: String, root: String?) {
        Task { await knowledge.study(repoID: repoID, root: root, followerID: device.followerID) }
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
            Text("Cameras").font(.headline)
            ForEach(lerobot.cameras) { c in
                if c.index == lerobot.mainCamera(device) {
                    Label("\(c.name) · main", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.muted)
                } else {
                    Toggle(c.name, isOn: extraBinding(c.name))
                }
            }
            Text("Camera not showing up? Connect it over USB in webcam mode; it'll appear here on its own.")
                .font(.caption).foregroundStyle(Theme.muted)
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
            FloatingPanel(tabs: [(.chat, "Chat"), (.control, "Control"), (.knowledge, "Knowledge")], selection: $tab) {
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
                    LiveControls(joints: RealAgentTools.joints, positions: live.joints, targets: live.targets,
                                 limits: live.limits, onChange: live.setTarget, onHome: live.home)
                        .disabled(!live.isReady)
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

/// Un panel del mosaico: su contenido en un contenedor redondeado, con su nombre.
private struct Tile<Content: View>: View {
    let title: String
    let focused: Bool
    let onTap: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Theme.fill
            content
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
        .overlay(alignment: .topLeading) {
            Text(title).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .padding(Theme.Space.s)
        }
        .overlay {
            // En los paneles chicos, un clic lo pasa a grande (el 3D grande se sigue pudiendo girar).
            if !focused { Color.clear.contentShape(.rect).onTapGesture(perform: onTap) }
        }
        .help(focused ? "" : "View large")
    }
}
