import SwiftUI

/// Lo que la IA sabe de una tarea por haber estudiado demostraciones, sin entrenar nada. Elegir qué estudiar
/// (de esta Mac o de Hugging Face), ver el paquete y activarlo para el chat. Solo dibuja: todo por props.
struct KnowledgePanel: View {
    let packages: [KnowledgePackage]
    let activeID: UUID?
    let studying: String?
    let error: String?
    let localDatasets: [DatasetInfo]
    let onStudy: (DatasetInfo) -> Void
    let onSearchHub: () -> Void
    let onActivate: (UUID?) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saber").font(.headline)
                    Text("La IA estudia demostraciones y escribe cómo se hace la tarea: etapas, poses y tramos que puede repetir en el robot. Sin entrenar.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                if let studying {
                    HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text(studying).font(.callout) }
                } else {
                    Menu {
                        Section("En esta Mac") {
                            ForEach(localDatasets.filter { $0.episodes > 0 }) { d in
                                Button("\(d.name) · \(d.episodes) demos") { onStudy(d) }
                            }
                        }
                        Divider()
                        Button("Buscar en Hugging Face…", action: onSearchHub)
                    } label: {
                        Label("Estudiar demostraciones", systemImage: "book")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
                if let error { Text(error).font(.callout).foregroundStyle(Theme.red) }

                ForEach(packages) { k in
                    PackageCard(package: k, active: k.id == activeID,
                                onToggle: { onActivate(k.id == activeID ? nil : k.id) },
                                onRemove: { onRemove(k.id) })
                }
            }
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }
}

private struct PackageCard: View {
    let package: KnowledgePackage
    let active: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.title).font(.callout.weight(.medium))
                    Text(package.source).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Toggle("Usar", isOn: Binding(get: { active }, set: { _ in onToggle() }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help(active ? "La IA lo está usando en el chat" : "Que la IA lo use en el chat")
            }
            Text(package.summary).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if expanded {
                section("Etapas", package.stages.enumerated().map { "\($0.offset + 1). \($0.element.name) — \($0.element.check)" })
                section("Poses", package.poses.map { "«\($0.name)» \($0.note)" })
                section("Tramos", package.segments.map { "«\($0.name)» demo \($0.episode), \($0.from)–\($0.to) s" })
                if !package.tips.isEmpty { section("Consejos", package.tips) }
                Button("Quitar", role: .destructive, action: onRemove).buttonStyle(.link).font(.caption)
            }
            Button(expanded ? "Menos" : "Ver todo") { withAnimation(.snappy) { expanded.toggle() } }
                .buttonStyle(.link).font(.caption)
        }
        .padding(Theme.Space.m)
        .background(Theme.fill, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(active ? Theme.ink.opacity(0.3) : Theme.hairline))
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(lines, id: \.self) { Text($0).font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
