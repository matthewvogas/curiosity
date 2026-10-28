import SwiftUI

// El resumen de un robot real, como la página de un proyecto en Figma: sus tareas, todos sus datos y lo
// que ha aprendido. Solo dibuja: datos y acciones llegan por props.

struct OverviewTask: Identifiable {
    let id: UUID
    let title: String
    let summary: String
    let phase: TaskPhase
    let fraction: Double?
}

struct OverviewModel: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ready: Bool
    let training: Bool
}

struct RobotOverview: View {
    let tasks: [OverviewTask]
    let datasets: [DatasetInfo]
    let models: [OverviewModel]
    let canRun: Bool
    let onOpenTask: (UUID) -> Void
    let onNewTask: () -> Void
    let onRevealDataset: (DatasetInfo) -> Void
    let onRunModel: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                section("Tareas", help: "Cada tarea tiene sus demostraciones, su entrenamiento y su prueba.") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.m)], spacing: Theme.Space.m) {
                        ForEach(tasks) { t in TaskCard(task: t) { onOpenTask(t.id) } }
                        NewTaskCard(action: onNewTask)
                    }
                }
                section("Datos", help: "Todas las demostraciones de esta Mac: las que grabaste y las bajadas de Hugging Face.") {
                    if datasets.isEmpty {
                        empty("Aún no hay demostraciones. Se crean al grabar una tarea.")
                    } else {
                        rows(datasets) { d in
                            row(icon: .dataset, title: d.name,
                                detail: "\(d.episodes) demostraciones · \(ByteCountFormatter.string(fromByteCount: Int64(d.bytes), countStyle: .file)) · \(d.source == "hub" ? "Hugging Face" : "grabado aquí")") {
                                Button { onRevealDataset(d) } label: { Icon(name: .eye) }
                                    .buttonStyle(.borderless).help("Mostrar en Finder")
                            }
                        }
                    }
                }
                section("Lo que aprendió", help: "Los modelos entrenados. Pruébalos en el robot cuando quieras.") {
                    if models.isEmpty {
                        empty("Todavía nada. Aparece aquí cuando termines de entrenar una tarea.")
                    } else {
                        rows(models) { m in
                            row(icon: .model, title: m.title, detail: m.detail) {
                                if m.training {
                                    Text("Entrenando").font(.caption).foregroundStyle(Theme.muted)
                                } else if m.ready {
                                    Button("Probar") { onRunModel(m.id) }.disabled(!canRun)
                                        .help(canRun ? "Que lo haga solo" : "Configura el follower y la cámara en Ajustes del robot")
                                } else {
                                    Text("Sin terminar").font(.caption).foregroundStyle(Theme.faint)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.xxl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(.title3.weight(.semibold)).help(help)
            content()
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.l)
            .background(Theme.fill.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.card))
    }

    private func rows<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().padding(.leading, 44) }
                row(item)
            }
        }
        .background(Theme.fill.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.card))
    }

    private func row<Trailing: View>(icon: IconName, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.m) {
            Icon(name: icon, size: 15).foregroundStyle(Theme.muted).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
    }
}

private struct TaskCard: View {
    let task: OverviewTask
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Icon(name: task.phase == .learned ? .taskLearned : task.phase == .training ? .taskTraining : .task, size: 18)
                    .foregroundStyle(task.phase == .learned ? Theme.ink : Theme.muted)
                Spacer(minLength: 0)
                Text(task.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                Text(task.summary).font(.caption).foregroundStyle(Theme.muted)
                if let f = task.fraction { ProgressView(value: f).controlSize(.small) }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(hovering ? Theme.selection : Theme.fill.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.card + 4))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 4).strokeBorder(Theme.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct NewTaskCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.s) {
                Icon(name: .add, size: 18)
                Text("Nueva tarea").font(.callout)
            }
            .foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 130)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 4)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
