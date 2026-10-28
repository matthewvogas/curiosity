import SwiftUI

// Enseñarle una tarea al robot real, en tres pasos guiados. Solo dibujan: datos y acciones por props.

/// Sin tareas: una sola pregunta, centrada como los estados vacíos de macOS, con un campo tipo composer.
struct TaskEmptyState: View {
    let onCreate: (String) -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    private static let examples = ["Pon el cubo rojo dentro del vaso", "Apila los dos bloques", "Empuja la pelota a la izquierda"]

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "hand.point.up.left.and.text")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, Theme.Space.xs)
                Text("¿Qué quieres que aprenda?").font(.title.weight(.semibold))
                Text("Se la muestras unas veces con el leader, se entrena y luego la hace solo.")
                    .font(.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }

            HStack(spacing: Theme.Space.s) {
                TextField("Describe la tarea", text: $title, prompt: Text("Describe la tarea en una frase"))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(create)
                Button(action: create) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(isEmpty)
                .help("Empezar (↩)")
            }
            .padding(.leading, Theme.Space.l)
            .padding(.trailing, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 520)

            VStack(spacing: Theme.Space.s) {
                Text("Ideas").font(.caption).foregroundStyle(Theme.faint)
                GlassEffectContainer {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Self.examples, id: \.self) { e in
                            Button(e) { title = e; focused = true }
                                .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            Label("Funciona mejor con tareas cortas, siempre iguales y a la vista de la cámara.", systemImage: "lightbulb")
                .font(.caption).foregroundStyle(Theme.faint)
                .padding(.bottom, Theme.Space.xl)
        }
        .onAppear { focused = true }
    }

    private var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    private func create() {
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { onCreate(t) }
    }
}

/// Estado de un paso del recorrido.
enum StepState { case done, current, waiting }

/// Un paso: número, título, una línea de estado, la acción principal y sus opciones (plegadas).
struct StepCard<Actions: View, Options: View>: View {
    let number: Int
    let title: String
    let state: StepState
    let status: String
    let help: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var options: Options
    @State private var showOptions = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            ZStack {
                Circle().fill(state == .waiting ? Theme.fill : Theme.ink.opacity(state == .done ? 0.12 : 0.9))
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.ink)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                        .foregroundStyle(state == .current ? Color(nsColor: .windowBackgroundColor) : Theme.muted)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).foregroundStyle(state == .waiting ? Theme.muted : Theme.ink)
                    Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(Theme.faint).help(help)
                    Spacer()
                    Button(showOptions ? "Ocultar opciones" : "Opciones") { withAnimation(.snappy) { showOptions.toggle() } }
                        .buttonStyle(.link).font(.caption)
                }
                Text(status).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if state != .waiting { actions }
                if showOptions {
                    VStack(alignment: .leading, spacing: Theme.Space.s) { options }
                        .padding(Theme.Space.m)
                        .background(Theme.fill, in: .rect(cornerRadius: Theme.Radius.card))
                        .controlSize(.small)
                }
            }
        }
        .padding(Theme.Space.l)
        .background(state == .current ? Theme.selection : .clear, in: .rect(cornerRadius: Theme.Radius.card + 4))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 4).strokeBorder(Theme.hairline))
        .opacity(state == .waiting ? 0.7 : 1)
    }
}

/// Grabando: la cámara grande, el contador y tres botones con su tecla.
struct RecordingView: View {
    let session: RobotSession
    let frame: Data?
    let onNext: () -> Void
    let onRedo: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            LivePicture(frame: frame).frame(maxHeight: 420)
            VStack(spacing: Theme.Space.xs) {
                Text(title).font(.title2.weight(.semibold))
                Text(hint).foregroundStyle(Theme.muted)
                if session.limit > 0 {
                    Text(Units.clock(session.remaining)).font(.system(size: 34, weight: .medium)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            HStack(spacing: Theme.Space.m) {
                Button("Repetir", action: onRedo).keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(session.phase != "recording").help("Descarta esta demostración y empieza otra vez (←)")
                Button(session.phase == "reset" ? "Listo, siguiente" : "Terminé esta demo", action: onNext)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!(session.phase == "recording" || session.phase == "reset")).help("→")
                Button("Detener y guardar", role: .destructive, action: onStop).keyboardShortcut(.escape, modifiers: [])
                    .help("Guarda las demostraciones terminadas; puedes seguir después (Esc)")
            }
            .controlSize(.large)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 720)
    }

    private var title: String {
        switch session.phase {
        case "starting": "Conectando los brazos y la cámara…"
        case "recording": "Demostración \(session.episode + 1) de \(session.target)"
        case "reset": "Prepara la siguiente"
        case "saving": "Guardando…"
        default: ""
        }
    }

    private var hint: String {
        switch session.phase {
        case "recording": "Haz la tarea con el leader, de principio a fin."
        case "reset": "No se graba. Deja los objetos como al empezar, cambiándolos un poco de lugar."
        case "starting": "El follower va a copiar al leader."
        default: ""
        }
    }
}

/// El robot usa el modelo: la cámara y un solo botón para detenerlo.
struct RunningView: View {
    let session: RobotSession
    let frame: Data?
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            LivePicture(frame: frame).frame(maxHeight: 420)
            Text(session.phase == "running" ? "El robot está haciendo la tarea · \(Units.clock(session.elapsed)) de \(Units.clock(session.limit))"
                 : session.phase == "returning" ? "Volviendo a la pose inicial…" : "Cargando el modelo y conectando…")
                .font(.title3).monospacedDigit()
            Button("Detener robot", role: .destructive, action: onStop)
                .buttonStyle(.borderedProminent).tint(Theme.red).controlSize(.large)
                .keyboardShortcut(.escape, modifiers: []).help("Esc")
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: 720)
    }
}

/// Buscar un dataset en Hugging Face y usarlo en lugar de grabar.
struct HubPickerView: View {
    let results: [HubDataset]
    @Binding var query: String
    let searching: Bool
    let onSearch: () -> Void
    let onPick: (HubDataset) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Datos de Hugging Face").font(.title2.weight(.semibold))
            Text("Demostraciones que otros grabaron con un SO-101. Entrenas con ellas en lugar de grabar las tuyas; se bajan solas.")
                .font(.callout).foregroundStyle(Theme.muted)
            HStack {
                TextField("Buscar", text: $query).textFieldStyle(.roundedBorder).onSubmit(onSearch)
                Button(searching ? "Buscando…" : "Buscar", action: onSearch).disabled(searching)
            }
            List(results) { d in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.id).lineLimit(1)
                        Text("\(d.downloads.formatted()) descargas").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Link(destination: d.url) { Image(systemName: "arrow.up.right.square") }.help("Ver en Hugging Face")
                    Button("Usar") { onPick(d) }
                }
            }
            .frame(minHeight: 280)
            HStack { Spacer(); Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction) }
        }
        .padding(Theme.Space.xl)
        .frame(width: 560, height: 520)
    }
}

/// La cámara del robot en vivo.
struct LivePicture: View {
    let frame: Data?

    var body: some View {
        Group {
            if let frame, let image = NSImage(data: frame) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(Theme.fill).overlay(ProgressView()).aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
    }
}

extension View {
    /// La acción principal del momento va destacada; las demás, normales.
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
    }
}
