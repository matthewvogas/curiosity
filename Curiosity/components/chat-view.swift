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
                    Label("History", systemImage: "clock.arrow.circlepath").font(.callout)
                }
                .buttonStyle(.borderless)
                .disabled(conversations.isEmpty)
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    HistoryList(conversations: conversations, currentID: currentID,
                                onOpen: { onOpenConversation($0); showingHistory = false },
                                onDelete: onDeleteConversation)
                }
                Spacer()
                Button(action: onNew) { Label("New", systemImage: IconName.clear.rawValue).font(.callout) }
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
                        ForEach(ChatEntry.group(items)) { entry in
                            switch entry {
                            case .item(let item): ChatRow(item: item, onApprove: onApprove, onReject: onReject).id(item.id)
                            case .photos(let id, let photos): PhotoStrip(photos: photos).id(id)
                            }
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
                case .approved: Text("Approved").font(.caption).foregroundStyle(Theme.muted)
                case .rejected: Text("Not approved").font(.caption).foregroundStyle(Theme.muted)
                }
            }
            Text(detail).font(.callout.monospacedDigit()).foregroundStyle(Theme.muted)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if state == .pending {
                HStack {
                    Spacer()
                    Button("No", action: onReject)
                    Button("Move", action: onApprove).buttonStyle(.borderedProminent)
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
                Text("Talk to \(robotName)").font(.title2.weight(.semibold))
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
                    Text("Connect an AI model").font(.callout.weight(.semibold))
                    Button("Open Settings", action: onOpenSettings)
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

/// Un renglón a dibujar: un mensaje, o varias fotos seguidas que la IA miró, juntas en un solo grupo.
private enum ChatEntry: Identifiable {
    case item(ChatItem)
    case photos(id: UUID, [Data])

    var id: UUID {
        switch self {
        case .item(let item): item.id
        case .photos(let id, _): id
        }
    }

    /// Las imágenes consecutivas se juntan: así una vuelta que miró por tres cámaras ocupa una línea.
    static func group(_ items: [ChatItem]) -> [ChatEntry] {
        var out: [ChatEntry] = []
        for item in items {
            if case .image(let jpeg) = item.kind {
                if case .photos(let id, let photos)? = out.last {
                    out[out.count - 1] = .photos(id: id, photos + [jpeg])
                } else {
                    out.append(.photos(id: item.id, [jpeg]))
                }
            } else {
                out.append(.item(item))
            }
        }
        return out
    }
}

/// Lo que la IA miró, discreto: cerrado dice cuántas fotos; abierto, miniaturas que se agrandan con un clic.
private struct PhotoStrip: View {
    let photos: [Data]
    @State private var open = false
    @State private var zoom: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: IconName.camera.rawValue).font(.system(size: 11))
                    Text(photos.count == 1 ? "1 photo" : "\(photos.count) photos").font(.callout)
                    Icon(name: .chevron, size: 9, weight: .semibold).rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(Theme.muted)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: Theme.Space.s)],
                          alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(photos.indices, id: \.self) { i in
                        Button { zoom = i } label: {
                            Image(nsImage: NSImage(data: photos[i]) ?? NSImage())
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                        }
                        .buttonStyle(.plain)
                        .help("Enlarge")
                    }
                }
            }
        }
        .sheet(item: Binding(get: { zoom.map(ZoomedPhoto.init) }, set: { zoom = $0?.id })) { z in
            VStack(spacing: Theme.Space.m) {
                HStack {
                    Text("Photo \(z.id + 1) of \(photos.count)").font(.headline)
                    Spacer()
                    Button("Done") { zoom = nil }.keyboardShortcut(.cancelAction)
                }
                Image(nsImage: NSImage(data: photos[z.id]) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: Theme.Radius.card))
            }
            .padding(Theme.Space.xl)
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    private struct ZoomedPhoto: Identifiable { let id: Int }
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
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action(let title, let detail, let running, let failed):
            ActionRow(title: title, detail: detail, running: running, failed: failed)
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

extension ChatRow {
    /// Markdown de la IA (negritas, código, enlaces) conservando sus saltos de línea y listas.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Las acciones de la IA, discretas: una fila que se despliega si trae detalle (abierta si falló).
private struct ActionRow: View {
    let title: String
    let detail: String
    let running: Bool
    let failed: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { if !detail.isEmpty { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Group {
                        if running { ProgressView().controlSize(.mini) }
                        else if detail.isEmpty { Text("›") }
                        else { Icon(name: .chevron, size: 9, weight: .semibold).rotationEffect(.degrees(isOpen ? 90 : 0)) }
                    }
                    .frame(width: 12)
                    Text(title).font(.callout).lineLimit(isOpen ? nil : 1)
                }
                .foregroundStyle(failed ? Theme.red : Theme.muted)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(detail.isEmpty)
            if isOpen, !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(failed ? Theme.red : Theme.faint)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
    }

    private var isOpen: Bool { open || failed }
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
    private let label = Text("Thinking…").font(.callout)

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
            .accessibilityLabel("Thinking")
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
            TextField("Message", text: $draft,
                      prompt: Text(enabled ? "Ask \(robotName) anything" : "Add your API key to get started"),
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
            .help(isRunning ? "Stop" : "Send")
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
                    .contextMenu { Button("Delete conversation", role: .destructive) { onDelete(c.id) } }
                }
            }
            .padding(Theme.Space.s)
        }
        .frame(width: 300)
        .frame(maxHeight: 360)
    }
}
