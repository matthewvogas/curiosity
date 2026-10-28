import SwiftUI

/// Control manual, como los paneles «Control» y «Joint» de MuJoCo: un deslizador por actuador
/// (objetivo) y, debajo, dónde está de verdad cada articulación.
struct JointControls: View {
    let joints: [JointInfo]
    let states: [JointState]
    let onChange: (String, Double) -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack {
                        Text("Control").font(.headline)
                        Spacer()
                        Button("Clear", action: onClear).buttonStyle(.link)
                        Button("Home pose", action: onReset).buttonStyle(.link)
                    }
                    if !joints.contains(where: \.actuated) {
                        Text("This robot has no actuated joints.").foregroundStyle(Theme.muted)
                    }
                    ForEach(joints.filter(\.actuated)) { joint in
                        ControlRow(joint: joint, state: states.first { $0.name == joint.name }) { onChange(joint.name, $0) }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Joints").font(.headline)
                    Text("Where each joint actually is, including coupled and unactuated ones.")
                        .font(.caption).foregroundStyle(Theme.muted)
                    ForEach(joints) { joint in
                        JointBar(joint: joint, state: states.first { $0.name == joint.name })
                    }
                }
            }
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }
}

private func range(of joint: JointInfo) -> ClosedRange<Double> {
    if let lo = joint.lower, let hi = joint.upper, hi > lo { return lo...hi }
    return joint.type == "prismatic" ? -0.5...0.5 : -Double.pi...Double.pi
}

private struct ControlRow: View {
    let joint: JointInfo
    let state: JointState?
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(joint.name).lineLimit(1)
                Spacer()
                Text(state.map { Units.format($0.target, jointType: joint.type) } ?? "—")
                    .monospacedDigit().foregroundStyle(Theme.muted)
            }
            Slider(value: Binding(get: { state?.target ?? 0 }, set: { onChange($0) }), in: range(of: joint))
                .controlSize(.small)
                .tint(Theme.ink.opacity(0.8))
        }
    }
}

/// Barra de solo lectura con la posición real dentro del rango.
private struct JointBar: View {
    let joint: JointInfo
    let state: JointState?

    var body: some View {
        let r = range(of: joint)
        let q = state?.q ?? 0
        let fraction = (min(max(q, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
        HStack(spacing: Theme.Space.m) {
            Text(joint.name).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.fill)
                    Capsule().fill(Theme.ink.opacity(0.55)).frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(Units.format(q, jointType: joint.type)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
