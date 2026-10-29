import SwiftUI

/// Las notas del robot para la IA (como un CLAUDE.md): lo que la app midió (solo lectura), lo que escribe la
/// persona y lo que aprendió la IA. Solo dibuja: todo por props.
struct RobotNotesPanel: View {
    let facts: [String]?
    let notes: String
    let learned: [String]
    let onNotes: (String) -> Void
    let onRemoveLesson: (Int) -> Void
    let onReveal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Notes").font(.headline)
                        Spacer()
                        Button("Show file", action: onReveal).buttonStyle(.link).font(.caption)
                    }
                    Text("Claude reads this in every conversation with this robot.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }

                section("Measured") {
                    if let facts, !facts.isEmpty {
                        Text(facts.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.muted)
                            .textSelection(.enabled)
                    } else {
                        Text("Load the robot to measure it.").font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                section("Your notes") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: Binding(get: { notes }, set: onNotes))
                            .font(.system(.callout, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 160)
                        if notes.isEmpty {
                            Text("Things Claude can't see: where things go on the table, the objects you use (size, weight), rules…")
                                .font(.callout).foregroundStyle(Theme.faint)
                                .padding(.top, 1).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(Theme.Space.s)
                    .background(Theme.fill, in: .rect(cornerRadius: Theme.Radius.row))
                }

                section("Learned") {
                    if learned.isEmpty {
                        Text("Claude adds what it learns here.").font(.caption).foregroundStyle(Theme.muted)
                    } else {
                        ForEach(Array(learned.enumerated()), id: \.offset) { i, lesson in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                                Text("•").foregroundStyle(Theme.faint)
                                Text(lesson).font(.callout).textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button(action: { onRemoveLesson(i) }) { Image(systemName: "xmark").font(.caption2) }
                                    .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                                    .help("Forget this")
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }
}
