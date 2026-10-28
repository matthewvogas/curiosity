import SwiftUI

/// La conversación: mensajes, acciones de la IA sobre el robot, imágenes que miró y el campo de texto.
struct ChatView: View {
    let items: [ChatItem]
    let isRunning: Bool
    let error: String?
    let hasKey: Bool
    let robotName: String
    let suggestions: [String]
    let conversations: [ConversationSummary]
    let currentID: UUID
    let onSend: (String) -> Void
    let onStop: () -> Void
    let onOpenSettings: () -> Void
    let onNew: () -> Void
    let onOpenConversation: (UUID) -> Void
    let onDeleteConversation: (UUID) -> Void
    /// Para el robot real: aprobar o no un movimiento que propone la IA.
    var onApprove: () -> Void = {}
    var onReject: () -> Void = {}

    @State private var draft = ""
    @State private var showingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showingHistory.toggle() } label: {
                    Label("Historial", systemImage: "clock.arrow.circlepath").font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(conversations.isEmpty)
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    HistoryList(conversations: conversations, currentID: currentID,
                                onOpen: { onOpenConversation($0); showingHistory = false },
                                onDelete: onDeleteConversation)
                }
                Spacer()
                Button(action: onNew) { Label("Nueva", systemImage: IconName.clear.rawValue).font(.callout) }
                    .buttonStyle(.borderless)
                    .disabled(items.isEmpty)
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                        if items.isEmpty {
                            ChatWelcome(robotName: robotName, hasKey: hasKey, suggestions: suggestions,
                                        onPick: { onSend($0) }, onOpenSettings: onOpenSettings)
                        }
                        ForEach(items) { item in
                            ChatRow(item: item, onApprove: onApprove, onReject: onReject).id(item.id)
                        }
                        if isRunning { ThinkingRow().id("thinking") }
                        if let error {
                            NoticeRow(text: error, isError: true)
                        }
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.vertical, Theme.Space.m)
                }
                .scrollIndicators(.never)
                // Los mensajes se desvanecen al llegar arriba y abajo, en lugar de cortarse en seco.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    }
                }
                .onChange(of: items.count) {
                    withAnimation(.snappy) {
                        if isRunning { proxy.scrollTo("thinking", anchor: .bottom) }
                        else if let last = items.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            ChatComposer(draft: $draft, isRunning: isRunning, enabled: hasKey, robotName: robotName,
                         onSend: { onSend(draft); draft = "" }, onStop: onStop)
                .padding(Theme.Space.m)
        }
    }
}

/// Un movimiento del robot real que propone la IA: el comando exacto y la decisión de la persona.
private struct ApprovalRow: View {
    let title: String
    let detail: String
    let state: ChatItem.ApprovalState
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Label(title, systemImage: "hand.raised").font(.callout.weight(.medium))
                Spacer()
                switch state {
                case .pending: EmptyView()
                case .approved: Text("Aprobado").font(.caption).foregroundStyle(Theme.muted)
                case .rejected: Text("No aprobado").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Text(detail).font(.callout.monospacedDigit()).foregroundStyle(Theme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if state == .pending {
                HStack {
                    Spacer()
                    Button("No", action: onReject)
                    Button("Mover", action: onApprove).buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.fill, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(state == .pending ? Theme.ink.opacity(0.25) : Theme.hairline))
    }
}

private struct ChatWelcome: View {
    let robotName: String
    let hasKey: Bool
    let suggestions: [String]
    let onPick: (String) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Habla con \(robotName)").font(.title2.weight(.semibold))
                Text("Pídele tareas en tus palabras. La IA mira la escena, planea y mueve el robot en la simulación.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }
            if hasKey {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { onPick(s) } label: {
                            Text(s).font(.callout).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, 9)
                            .background(Theme.fill, in: .rect(cornerRadius: Theme.Radius.card))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Conecta un modelo de IA").font(.callout.weight(.semibold))
                    Text("Pega tu API key de Anthropic. Se guarda en el Llavero de tu Mac.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Button("Abrir Ajustes", action: onOpenSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fill, in: .rect(cornerRadius: Theme.Radius.card))
            }
        }
        .padding(.top, Theme.Space.l)
    }
}

private struct ChatRow: View {
    let item: ChatItem
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(0.09), in: .rect(cornerRadius: 18))
            }
        case .assistant(let text):
            Text(LocalizedStringKey(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action(let title, let detail, let running, let failed):
            // Las acciones de la IA, discretas: solo texto (con un indicador mientras corren).
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                if running { ProgressView().controlSize(.mini) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).foregroundStyle(failed ? Theme.red : Theme.muted)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(failed ? Theme.red : Theme.faint) }
                }
            }
        case .image(let jpeg):
            Image(nsImage: NSImage(data: jpeg) ?? NSImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, alignment: .leading)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        case .notice(let text, let isError):
            NoticeRow(text: text, isError: isError)
        case .approval(let title, let detail, let state):
            ApprovalRow(title: title, detail: detail, state: state, onApprove: onApprove, onReject: onReject)
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text).font(.callout)
            .foregroundStyle(isError ? Theme.red : Theme.muted)
    }
}

/// «Pensando…» con un brillo que lo recorre de izquierda a derecha.
private struct ThinkingRow: View {
    private let label = Text("Pensando…").font(.callout)

    var body: some View {
        label
            .foregroundStyle(Theme.muted)
            .overlay {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                    GeometryReader { g in
                        let band = g.size.width * 0.5
                        LinearGradient(colors: [.clear, Theme.ink, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + phase * (g.size.width + band))
                    }
                }
                .mask(label)
            }
            .accessibilityLabel("Pensando")
    }
}

/// Campo para escribir: relleno sutil (no vidrio, porque ya está sobre el panel de vidrio).
/// El campo para escribirle al robot, como el de Mensajes en macOS 26: cristal, texto que crece y el botón
/// de enviar del sistema.
private struct ChatComposer: View {
    @Binding var draft: String
    let isRunning: Bool
    let enabled: Bool
    let robotName: String
    let onSend: () -> Void
    let onStop: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.s) {
            TextField("Mensaje", text: $draft,
                      prompt: Text(enabled ? "Pídele algo a \(robotName)" : "Conecta tu API key para empezar"),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.vertical, 5)  // una línea mide lo mismo que el botón: quedan centrados
                .disabled(!enabled)
                .onSubmit { if !isRunning { onSend() } }
            Button(action: isRunning ? onStop : onSend) {
                Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(active ? Color.white : Theme.faint)
                    .frame(width: Self.button, height: Self.button)
                    .glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(!isRunning && !canSend)
            .keyboardShortcut(isRunning ? .cancelAction : .defaultAction)
            .help(isRunning ? "Detener" : "Enviar")
        }
        .padding(.leading, Theme.Space.m)
        .padding([.vertical, .trailing], Self.inset)
        // Esquinas concéntricas con el botón: mismo margen arriba, abajo y a la derecha.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.button / 2 + Self.inset))
        .contentShape(.rect)
        .onTapGesture { focused = true }
    }

    private static let button: CGFloat = 28
    private static let inset: CGFloat = 6
    private var active: Bool { canSend || isRunning }

    private var canSend: Bool { enabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Conversaciones anteriores con el robot: clic para retomarla, clic derecho para borrarla.
private struct HistoryList: View {
    let conversations: [ConversationSummary]
    let currentID: UUID
    let onOpen: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(conversations) { c in
                    Button { onOpen(c.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(.callout.weight(c.id == currentID ? .semibold : .regular)).lineLimit(1)
                            Text(c.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, 6)
                        .background(c.id == currentID ? Theme.selection : .clear, in: .rect(cornerRadius: Theme.Radius.row))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Borrar conversación", role: .destructive) { onDelete(c.id) } }
                }
            }
            .padding(Theme.Space.s)
        }
        .frame(width: 300)
        .frame(maxHeight: 360)
    }
}
