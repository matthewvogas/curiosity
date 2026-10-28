import SwiftUI

/// Antes de grabar o probar: cada pieza revisada (sin mover nada), lo que ve la cámara y qué va a pasar.
/// Empezar solo se habilita cuando nada falla. Solo dibuja: todo por props.
struct PreflightView: View {
    let title: String
    let checks: [PreflightCheck]
    let picture: Data?
    let checking: Bool
    let warning: String
    let startTitle: String
    let onRetry: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void
    let onFix: () -> Void
    let onOpenPrivacy: () -> Void

    private var failed: Bool { checks.contains { $0.state == .fail } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    if checking && checks.isEmpty {
                        HStack(spacing: Theme.Space.s) { ProgressView().controlSize(.small); Text("Checking each part…").foregroundStyle(Theme.muted) }
                    }
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Image(systemName: icon(c.state)).foregroundStyle(color(c.state)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title)
                                Text(c.detail).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                if c.state == .fail {
                                    Button(c.key == "permission" ? "Open System Settings" : "Robot settings",
                                           action: c.key == "permission" ? onOpenPrivacy : onFix)
                                        .buttonStyle(.link).font(.callout)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if let picture, let image = NSImage(data: picture) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Theme.fill).aspectRatio(4 / 3, contentMode: .fit)
                            .overlay(Image(systemName: "video.slash").foregroundStyle(Theme.faint))
                    }
                }
                .frame(width: 220)
                .clipShape(.rect(cornerRadius: 10))
            }

            if !failed && !checks.isEmpty {
                Text(warning).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Check again", action: onRetry).disabled(checking)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(startTitle, action: onStart)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking || failed || checks.isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 600)
    }

    private func icon(_ s: PreflightCheck.State) -> String {
        switch s {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    private func color(_ s: PreflightCheck.State) -> Color {
        switch s {
        case .ok: .green
        case .warn: .orange
        case .fail: Theme.red
        }
    }
}
