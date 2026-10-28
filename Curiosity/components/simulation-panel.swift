import SwiftUI

/// Las opciones de la simulación, como el panel izquierdo de MuJoCo (`simulate`), en secciones plegables:
/// Simulación, Física, Visualización, Info, Sensores y Archivo.
struct SimulationPanel: View {
    let state: SimulationState
    let model: RobotModel?
    @Binding var physics: PhysicsSettings
    @Binding var render: RenderOptions
    let keyframes: [Keyframe]
    let speed: Double
    let onTogglePause: () -> Void
    let onReset: () -> Void
    let onReload: () -> Void
    let onAlign: () -> Void
    let onCopyState: () -> Void
    let onSpeed: (Double) -> Void
    let onSaveKey: () -> Void
    let onLoadKey: (Keyframe) -> Void
    let onDeleteKey: (Keyframe) -> Void
    let onScreenshot: () -> Void
    let onShowModel: () -> Void

    @AppStorage("panel.sections") private var closed = "Info,Sensors"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                section("Simulation") {
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: state.paused ? "Run" : "Pause", prominent: true, action: onTogglePause)
                        PillButton(title: "Reset", action: onReset)
                    }
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: "Reload", action: onReload)
                        PillButton(title: "Align", action: onAlign)
                        PillButton(title: "Copy state", action: onCopyState)
                    }
                    Row("Speed") {
                        Picker("", selection: Binding(get: { speed }, set: { onSpeed($0) })) {
                            ForEach([0.1, 0.25, 0.5, 1, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    ValueSlider(title: "Noise · scale", value: $physics.noiseScale, range: 0...0.5, format: "%.2f")
                    ValueSlider(title: "Noise · rate", value: $physics.noiseRate, range: 0...2, format: "%.2f s")

                    HStack {
                        Text("Saved poses").font(.callout.weight(.medium))
                        Spacer()
                        Button("Save current", action: onSaveKey).buttonStyle(.link).font(.callout)
                    }
                    .padding(.top, Theme.Space.xs)
                    if keyframes.isEmpty {
                        Text("Save the pose of the robot and objects to come back to it anytime.")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    ForEach(keyframes) { key in
                        HStack {
                            Button(key.name) { onLoadKey(key) }.buttonStyle(.link)
                            Spacer()
                            Text(key.savedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(Theme.faint)
                            Button { onDeleteKey(key) } label: { Icon(name: .trash, size: 11) }
                                .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                        }
                        .font(.callout)
                    }
                }

                section("Physics") {
                    ValueSlider(title: "Gravity", value: $physics.gravity, range: 0...20, format: "%.2f m/s²")
                    ValueSlider(title: "Friction", value: $physics.friction, range: 0...1.5, format: "%.2f")
                    ValueSlider(title: "Bounce", value: $physics.restitution, range: 0...0.9, format: "%.2f")
                    Row("Timestep") {
                        Picker("", selection: $physics.timestep) {
                            Text("1 ms").tag(1.0 / 1000); Text("2 ms").tag(1.0 / 500); Text("4 ms").tag(1.0 / 250); Text("8 ms").tag(1.0 / 125)
                        }
                        .labelsHidden().fixedSize()
                    }
                    ValueSlider(title: "Iterations", value: $physics.iterations, range: 1...30, format: "%.0f", step: 1)
                    Switch("Self-collisions", isOn: $physics.selfCollision)
                }

                section("Rendering") {
                    Switch("Contacts", isOn: $render.contacts)
                    Switch("Joint axes", isOn: $render.joints)
                    Switch("Collision shapes", isOn: $render.collision)
                    Switch("Centers of mass", isOn: $render.com)
                    Switch("Transparent robot", isOn: $render.transparent)
                    Switch("Grid", isOn: $render.grid)
                    Switch("Shadows", isOn: $render.shadows)
                }

                section("Info") {
                    Stat("Time", String(format: "%.2f s", state.time))
                    Stat("Real-time factor", String(format: "%.2f×", state.realTimeFactor))
                    Stat("Physics step", String(format: "%.3f ms", state.stepMs))
                    Stat("Links", "\(model?.links.count ?? 0)")
                    Stat("Moving joints", "\(model?.joints.count ?? 0)")
                    Stat("Actuated", "\(model?.actuatedJoints.count ?? 0)")
                    Stat("Base", model?.floating == true ? "Free" : "Fixed")
                    Stat("Total mass", String(format: "%.3f kg", model?.mass ?? 0))
                    Stat("Contacts", "\(state.contacts)")
                }

                section("Sensors") {
                    Text("Estimated force per motor").font(.caption).foregroundStyle(Theme.muted)
                    ForEach(state.joints, id: \.name) { j in
                        Stat(j.name, String(format: "%.2f", j.force))
                    }
                    Text("Contact force per link").font(.caption).foregroundStyle(Theme.muted).padding(.top, Theme.Space.xs)
                    if state.linkForces.isEmpty { Text("No contacts").font(.callout).foregroundStyle(Theme.faint) }
                    ForEach(state.linkForces.sorted { $0.key < $1.key }, id: \.key) { name, force in
                        Stat(name, String(format: "%.2f N", force))
                    }
                }

                section("File") {
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: "Screenshot", action: onScreenshot)
                        PillButton(title: "View model", action: onShowModel)
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    /// Sección plegable; recuerda cuáles quedaron cerradas.
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let body = content()
        let open = Binding(
            get: { !closed.split(separator: ",").contains(Substring(title)) },
            set: { isOpen in
                var set = Set(closed.split(separator: ",").map(String.init))
                if isOpen { set.remove(title) } else { set.insert(title) }
                closed = set.sorted().joined(separator: ",")
            })
        return DisclosureGroup(isExpanded: open) {
            VStack(alignment: .leading, spacing: Theme.Space.m) { body }
                .padding(.top, Theme.Space.s)
                .padding(.bottom, Theme.Space.m)
        } label: {
            Text(title).font(.headline)
        }
    }
}

private struct Row<C: View>: View {
    let title: String
    @ViewBuilder var content: C
    init(_ title: String, @ViewBuilder content: () -> C) { self.title = title; self.content = content() }

    var body: some View {
        HStack { Text(title); Spacer(); content }
    }
}

/// Interruptor con el texto a la izquierda y el control alineado a la derecha.
private struct Switch: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; _isOn = isOn }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden()
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

/// Botón de acción dentro del panel: relleno sutil (el panel ya es de vidrio).
struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(prominent ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : Theme.ink)
                .background(prominent ? Theme.ink.opacity(0.9) : Theme.fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// Deslizador con su título y valor.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    var step: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            if let step {
                Slider(value: $value, in: range, step: step).tint(Theme.ink.opacity(0.8))
            } else {
                Slider(value: $value, in: range).tint(Theme.ink.opacity(0.8))
            }
        }
    }
}
