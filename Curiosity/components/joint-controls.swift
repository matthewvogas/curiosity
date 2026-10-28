import SwiftUI

/// Control manual: un deslizador por articulación (objetivo) con su posición real debajo.
struct JointControls: View {
    let joints: [JointInfo]
    let states: [JointState]
    let onChange: (String, Double) -> Void
    let onReset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack {
                    Text("Articulaciones").font(.headline)
                    Spacer()
                    Button("Pose inicial", action: onReset).buttonStyle(.link).font(.callout)
                }
                if joints.isEmpty {
                    Text("Este robot no tiene articulaciones móviles.").font(.callout).foregroundStyle(Theme.muted)
                }
                ForEach(joints) { joint in
                    JointRow(joint: joint, state: states.first { $0.name == joint.name }) { onChange(joint.name, $0) }
                }
                Text("La barra es el objetivo del motor; el número, dónde está de verdad. Si algo lo bloquea, no llega.")
                    .font(.caption).foregroundStyle(Theme.faint)
            }
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }
}

private struct JointRow: View {
    let joint: JointInfo
    let state: JointState?
    let onChange: (Double) -> Void

    private var range: ClosedRange<Double> {
        if let lo = joint.lower, let hi = joint.upper, hi > lo { return lo...hi }
        return joint.type == "prismatic" ? -0.5...0.5 : -Double.pi...Double.pi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(joint.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Text(state.map { Units.format($0.q, jointType: joint.type) } ?? "—")
                    .font(.callout).monospacedDigit().foregroundStyle(Theme.muted)
                    .contentTransition(.numericText())
            }
            Slider(value: Binding(get: { state?.target ?? 0 }, set: onChange), in: range)
                .controlSize(.small)
                .tint(Theme.ink.opacity(0.8))
        }
    }
}
