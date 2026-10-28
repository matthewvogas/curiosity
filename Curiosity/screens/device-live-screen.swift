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
    @Environment(\.openSettings) private var openSettings

    enum PanelTab: String, Hashable { case chat, control }
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
                        Section("Cámaras en vivo") {
                            ForEach(lerobot.cameras) { c in
                                if c.index == device.cameraIndex {
                                    Text("\(c.name) · principal")
                                } else {
                                    Toggle(c.name, isOn: extraBinding(c.index))
                                }
                            }
                        }
                        Text("¿No aparece? Conéctala por USB en modo webcam.")
                    } label: {
                        Label("Cámaras", systemImage: "video.badge.plus")
                    }
                    .help("Agregar o quitar cámaras sin desconectar el robot")
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
            Tile(title: "Modelo 3D", focused: focused == cams.count, onTap: { focused = cams.count }) {
                SimStage(engine: live.twin)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Label(live.isReturning ? "Volviendo a su pose…" : live.isReady ? "En vivo" : "Conectando…",
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
                Text("Contrólalo en vivo").font(.title.weight(.semibold))
                Text("Háblale o muévelo con los controles, mirando por su cámara.\nAl conectar se queda firme en su pose; al soltarlo vuelve a ella y se relaja.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
            }
            Button("Conectar", action: onConnect)
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(!device.canRunPolicy || lerobot.isBusy)
            if !device.canRunPolicy {
                Text("Elige la calibración del follower y la cámara en Ajustes del robot.").font(.callout).foregroundStyle(Theme.muted)
            }
            cameraPicker
            if let error = lerobot.error {
                Text(error).font(.callout).foregroundStyle(Theme.red).multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Activar o quitar una cámara extra; si ya está en vivo, se aplica sin desconectar.
    private func extraBinding(_ index: Int) -> Binding<Bool> {
        Binding(get: { device.extras.contains(index) }, set: { on in
            let next = on ? device.extras + [index] : device.extras.filter { $0 != index }
            devices.update(device.id) { $0.extraCameras = next }
            if live.isLive { live.setExtraCameras(next) }
        })
    }

    /// Qué cámaras se ven en vivo: la principal (la de grabar) y las que actives.
    private var cameraPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Cámaras").font(.headline)
            ForEach(lerobot.cameras) { c in
                if c.index == device.cameraIndex {
                    Label("\(c.name) · principal", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.muted)
                } else {
                    Toggle(c.name, isOn: extraBinding(c.index))
                }
            }
            Text("¿No aparece una? Conéctala por USB en modo webcam; sale aquí sola.")
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
            FloatingPanel(tabs: [(.chat, "Chat"), (.control, "Control")], selection: $tab) {
                switch tab {
                case .chat:
                    if let chat {
                        ChatView(items: chat.items, isRunning: chat.isRunning, error: chat.error,
                                 hasKey: settings.hasAnthropicKey, robotName: robotName,
                                 suggestions: ["¿Qué ves en la mesa?", "Abre un poco la pinza", "Saluda moviendo la muñeca"],
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
        .help(focused ? "" : "Ver en grande")
    }
}
