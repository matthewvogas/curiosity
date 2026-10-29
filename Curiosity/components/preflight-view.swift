import SwiftUI

/// El leader, para elegirlo ahí mismo cuando la acción lo necesita.
struct PreflightLeader {
    let ports: [String]
    let calibrations: [String]
    @Binding var port: String?
    @Binding var id: String?
}

/// Antes de grabar o probar: cada pieza que se va a usar, revisada (sin mover nada), y qué va a pasar.
/// Empezar solo se habilita cuando nada falla. Solo dibuja: todo por props.
struct PreflightView: View {
    let title: String
    let checks: [PreflightCheck]
    /// Si la acción necesita el leader (grabar, moverlo con el leader).
    let leader: PreflightLeader?
    let checking: Bool
    let warning: String
    let startTitle: String
    let onRetry: () -> Void
    let onStart: () -> Void
    let onCancel: () -> Void
    /// Arreglar una revisión que falló (recibe su clave).
    let onFix: (String) -> Void
    let onOpenPrivacy: () -> Void

    private var failed: Bool { checks.contains { $0.state == .fail } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title).font(.title2.weight(.semibold))

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
                                if c.state == .fail && c.key != "leader" {
                                    Button(fixTitle(c.key), action: { c.key == "permission" ? onOpenPrivacy() : onFix(c.key) })
                                        .buttonStyle(.link).font(.callout)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            if let leader {
                // El leader se elige aquí mismo; «Check again» lo revisa.
                Form {
                    Picker("Leader port", selection: leader.$port) {
                        Text("Choose…").tag(String?.none)
                        ForEach(leader.ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag(String?.some($0)) }
                    }
                    Picker("Leader calibration", selection: leader.$id) {
                        Text("Choose…").tag(String?.none)
                        ForEach(leader.calibrations, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 110)
                .onChange(of: leader.port) { onRetry() }
                .onChange(of: leader.id) { onRetry() }
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

    private func fixTitle(_ key: String) -> String {
        switch key {
        case "permission": "Open System Settings"
        case "cameras", "camera", _ where key.hasPrefix("cam"): "Choose cameras"
        default: "Robot settings"
        }
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
