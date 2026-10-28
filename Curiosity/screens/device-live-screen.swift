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
    @Environment(\.liveChat) private var chat
    @Environment(\.openSettings) private var openSettings

    enum PanelTab: String, Hashable { case chat, control }
    @AppStorage("live.tab") private var tab: PanelTab = .chat

    var body: some View {
        Group {
            if live.isLive {
                stage
            } else {
                start
            }
        }
        .task(id: device.id) {
            let key = "device-" + device.id
            if chat?.robotID != key { chat?.reset(robotName: robotName, robotID: key) }
        }
    }

    private var camera: some View {
        Group {
            if let frame = live.frame, let image = NSImage(data: frame) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Theme.fill).aspectRatio(4 / 3, contentMode: .fit)
                    .overlay(ProgressView())
            }
        }
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .overlay(alignment: .bottomLeading) {
            Label(live.isReturning ? "Volviendo a su pose…" : live.isReady ? "En vivo" : "Conectando…",
                  systemImage: live.isReady ? "circle.fill" : "circle.dotted")
                .font(.caption.weight(.medium))
                .foregroundStyle(live.isReady ? Theme.ink : Theme.muted)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(Theme.Space.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let error = lerobot.error {
                Text(error).font(.callout).foregroundStyle(Theme.red).multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stage: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()
            // La cámara en su propio contenedor, centrada en lo que deja libre el panel.
            camera
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
