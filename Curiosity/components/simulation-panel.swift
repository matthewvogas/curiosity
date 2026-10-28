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

    @AppStorage("panel.sections") private var closed = "Info,Sensores"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                section("Simulación") {
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: state.paused ? "Correr" : "Pausar", prominent: true, action: onTogglePause)
                        PillButton(title: "Reiniciar", action: onReset)
                    }
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: "Recargar", action: onReload)
                        PillButton(title: "Alinear", action: onAlign)
                        PillButton(title: "Copiar estado", action: onCopyState)
                    }
                    Row("Velocidad") {
                        Picker("", selection: Binding(get: { speed }, set: { onSpeed($0) })) {
                            ForEach([0.1, 0.25, 0.5, 1, 2, 4], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    ValueSlider(title: "Ruido · escala", value: $physics.noiseScale, range: 0...0.5, format: "%.2f")
                    ValueSlider(title: "Ruido · tiempo", value: $physics.noiseRate, range: 0...2, format: "%.2f s")

                    HStack {
                        Text("Poses guardadas").font(.callout.weight(.medium))
                        Spacer()
                        Button("Guardar actual", action: onSaveKey).buttonStyle(.link).font(.callout)
                    }
                    .padding(.top, Theme.Space.xs)
                    if keyframes.isEmpty {
                        Text("Guarda la pose del robot y de los objetos para volver a ella cuando quieras.")
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

                section("Física") {
                    ValueSlider(title: "Gravedad", value: $physics.gravity, range: 0...20, format: "%.2f m/s²")
                    ValueSlider(title: "Fricción", value: $physics.friction, range: 0...1.5, format: "%.2f")
                    ValueSlider(title: "Rebote", value: $physics.restitution, range: 0...0.9, format: "%.2f")
                    Row("Paso de tiempo") {
                        Picker("", selection: $physics.timestep) {
                            Text("1 ms").tag(1.0 / 1000); Text("2 ms").tag(1.0 / 500); Text("4 ms").tag(1.0 / 250); Text("8 ms").tag(1.0 / 125)
                        }
                        .labelsHidden().fixedSize()
                    }
                    ValueSlider(title: "Iteraciones", value: $physics.iterations, range: 1...30, format: "%.0f", step: 1)
                    Switch("Choques del robot consigo mismo", isOn: $physics.selfCollision)
                }

                section("Visualización") {
                    Switch("Contactos", isOn: $render.contacts)
                    Switch("Ejes de las articulaciones", isOn: $render.joints)
                    Switch("Formas de colisión", isOn: $render.collision)
                    Switch("Centros de masa", isOn: $render.com)
                    Switch("Robot transparente", isOn: $render.transparent)
                    Switch("Cuadrícula", isOn: $render.grid)
                    Switch("Sombras", isOn: $render.shadows)
                }

                section("Info") {
                    Stat("Tiempo", String(format: "%.2f s", state.time))
                    Stat("Velocidad real", String(format: "%.2f×", state.realTimeFactor))
                    Stat("Paso de física", String(format: "%.3f ms", state.stepMs))
                    Stat("Piezas", "\(model?.links.count ?? 0)")
                    Stat("Articulaciones móviles", "\(model?.joints.count ?? 0)")
                    Stat("Con motor", "\(model?.actuatedJoints.count ?? 0)")
                    Stat("Base", model?.floating == true ? "Libre" : "Fija")
                    Stat("Masa total", String(format: "%.3f kg", model?.mass ?? 0))
                    Stat("Contactos", "\(state.contacts)")
                }

                section("Sensores") {
                    Text("Fuerza estimada de cada motor").font(.caption).foregroundStyle(Theme.muted)
                    ForEach(state.joints, id: \.name) { j in
                        Stat(j.name, String(format: "%.2f", j.force))
                    }
                    Text("Fuerza de contacto por pieza").font(.caption).foregroundStyle(Theme.muted).padding(.top, Theme.Space.xs)
                    if state.linkForces.isEmpty { Text("Sin contactos").font(.callout).foregroundStyle(Theme.faint) }
                    ForEach(state.linkForces.sorted { $0.key < $1.key }, id: \.key) { name, force in
                        Stat(name, String(format: "%.2f N", force))
                    }
                }

                section("Archivo") {
                    HStack(spacing: Theme.Space.s) {
                        PillButton(title: "Captura de pantalla", action: onScreenshot)
                        PillButton(title: "Ver el modelo", action: onShowModel)
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
