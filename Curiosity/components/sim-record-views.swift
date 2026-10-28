import SwiftUI

/// Antes de grabar en la simulación: qué tarea, cuántas demostraciones y con qué leader.
struct SimRecordSheet: View {
    let leaders: [Device]
    let onStart: (Device, String, Int, Double) -> Void
    let onCancel: () -> Void
    @State private var task = ""
    @State private var episodes = 20
    @State private var seconds = 30.0
    @State private var leaderID: String?

    var body: some View {
        Form {
            Section {
                TextField("Tarea", text: $task, prompt: Text("Pon el cubo rojo dentro de la caja"))
                Stepper("\(episodes) demostraciones", value: $episodes, in: 1...200, step: 5)
                Stepper("Hasta \(Int(seconds)) s cada una", value: $seconds, in: 5...300, step: 5)
                if leaders.count > 1 {
                    Picker("Leader", selection: $leaderID) {
                        ForEach(leaders) { Text($0.name.isEmpty ? ($0.guess ?? "SO-101") : $0.name).tag(String?.some($0.id)) }
                    }
                }
            } header: {
                Text("Grabar en la simulación")
            } footer: {
                Text("Mueves tu leader y el robot simulado lo copia; se graba su cámara y sus movimientos como un dataset de LeRobot (para entrenar o para «Saber»). El brazo real no se conecta. Teclas: → terminar, ← repetir, Esc guardar.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Grabar") {
                    if let d = leaders.first(where: { $0.id == leaderID }) ?? leaders.first {
                        onStart(d, task.trimmingCharacters(in: .whitespaces), episodes, seconds)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty || leaders.isEmpty)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 480, height: 360)
    }
}

/// Mientras graba en la simulación: en qué va, el tiempo y los tres botones con su tecla.
struct SimRecordBar: View {
    let session: RobotSession
    let onNext: () -> Void
    let onRedo: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: session.phase == "recording" ? "record.circle.fill" : "pause.circle")
                .foregroundStyle(session.phase == "recording" ? Theme.red : Theme.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.callout.weight(.medium))
                if session.limit > 0 {
                    Text(Units.clock(session.remaining)).font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }
            Divider().frame(height: 24)
            Button("Repetir", action: onRedo).keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(session.phase != "recording").help("←")
            Button(session.phase == "reset" ? "Siguiente" : "Terminé", action: onNext)
                .buttonStyle(.borderedProminent).keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!(session.phase == "recording" || session.phase == "reset")).help("→")
            Button("Guardar", action: onStop).keyboardShortcut(.escape, modifiers: []).help("Esc")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .glassEffect(.regular, in: .capsule)
    }

    private var title: String {
        switch session.phase {
        case "starting": "Conectando el leader…"
        case "recording": "Demostración \(session.episode + 1) de \(session.target)"
        case "reset": "Acomoda la escena"
        case "saving": "Guardando…"
        default: ""
        }
    }
}
