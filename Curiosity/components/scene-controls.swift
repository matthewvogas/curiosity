import SwiftUI

/// Escena: los objetos (cada uno se abre para ver y cambiar dónde está, su giro, peso, color y si está fijo),
/// cómo moverlos con el mouse y agregar una forma simple. Para crear cosas reales («un escritorio»), el chat.
struct SceneControls: View {
    let objects: [SceneObject]
    /// Dónde está cada objeto ahora (m, marco de la base), del estado en vivo.
    let positions: [Int: [Double]]
    let onAdd: (SceneObject) -> Void
    /// Cambios en unidades del motor: {pos (m), yaw (grados), mass (kg), color, fixed}.
    let onUpdate: (Int, [String: Any]) -> Void
    /// Dónde está y cómo está girado un objeto ahora (para empezar a editarlo).
    let onPose: (Int) async -> (pos: [Double], yaw: Double)?
    let onRemove: (Int) -> Void

    @State private var expanded: Int?
    @State private var shape = "box"
    @State private var sizeCM = 3.0
    @State private var massG = 20.0
    @State private var color = Color(red: 0.89, green: 0.34, blue: 0.18)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                section(objects.isEmpty ? "Objects" : "Objects · \(objects.count)") {
                    if objects.isEmpty {
                        Text("Nothing on the table yet. Add a shape below, or ask in the chat: “put a coffee mug on the table”.")
                            .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 2) {
                        ForEach(objects) { o in
                            VStack(alignment: .leading, spacing: 0) {
                                row(o)
                                if expanded == o.id {
                                    ObjectDetail(object: o, position: positions[o.id] ?? o.pos,
                                                 onUpdate: { onUpdate(o.id, $0) }, onPose: { await onPose(o.id) },
                                                 onRemove: { expanded = nil; onRemove(o.id) })
                                        .id(o.id)
                                        .padding([.horizontal, .bottom], Theme.Space.s)
                                }
                            }
                            .background(expanded == o.id ? Theme.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Icon(name: .hand, size: 12)
                        Text("Drag an object to move it, scroll while dragging to lift it, Shift + scroll or Q / E to turn it.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption).foregroundStyle(Theme.muted)
                }

                section("Add a shape") {
                    Picker("Shape", selection: $shape) {
                        Text("Box").tag("box"); Text("Sphere").tag("sphere"); Text("Cylinder").tag("cylinder")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    LabeledSlider(title: "Size", value: $sizeCM, range: 1...30, text: Units.length(sizeCM / 100))
                    LabeledSlider(title: "Mass", value: $massG, range: 1...2000, text: Units.weight(massG / 1000))
                    HStack {
                        ColorPicker("Color", selection: $color).font(.callout)
                        Spacer()
                        Button("Drop on the table") { onAdd(newObject) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    /// Una fila: color, nombre, medidas, peso y dónde está; un clic la abre o la cierra.
    private func row(_ o: SceneObject) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == o.id ? nil : o.id }
        } label: {
            HStack(spacing: Theme.Space.s) {
                Icon(name: .chevron, size: 9, weight: .semibold)
                    .foregroundStyle(Theme.faint)
                    .rotationEffect(.degrees(expanded == o.id ? 90 : 0))
                Circle().fill(Color(hex: o.displayColor)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.name(o)).font(.callout).lineLimit(1)
                    Text("\(Self.sizeText(o)) · \(Units.weight(o.mass))\(o.fixed ? " · fixed" : "")")
                        .font(.caption).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(Units.centimeters(positions[o.id] ?? o.pos).map { String(format: "%.0f", $0) }.joined(separator: ", "))
                    .font(.caption).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.s).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func name(_ o: SceneObject) -> String { o.name.isEmpty ? label(o.shape) : o.name }

    /// Lo que mide (largo × ancho × alto), en cm o en m si pasa de un metro.
    private static func sizeText(_ o: SceneObject) -> String {
        let d = o.extent
        if (d.max() ?? 0) >= 1 { return d.map { String(format: "%g", ($0 * 100).rounded() / 100) }.joined(separator: " × ") + " m" }
        return d.map { String(format: "%g", ($0 * 1000).rounded() / 10) }.joined(separator: " × ") + " cm"
    }

    /// Una forma simple nueva: el motor elige un lugar libre y la suelta.
    private var newObject: SceneObject {
        let s = sizeCM / 100
        let size: [Double] = shape == "sphere" ? [s / 2] : shape == "cylinder" ? [s / 2, s] : [s, s, s]
        return SceneObject(id: 0, shape: shape, size: size, mass: massG / 1000, color: color.hex, pos: [0, 0, 0])
    }

    static func label(_ shape: String) -> String {
        switch shape { case "sphere": "Sphere"; case "cylinder": "Cylinder"; case "capsule": "Capsule"; default: "Box" }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// El detalle de un objeto abierto: cada valor se ve en vivo y se cambia ahí mismo (Enter o salir del campo lo
/// aplica, Esc lo deja como estaba).
private struct ObjectDetail: View {
    let object: SceneObject
    let position: [Double]
    let onUpdate: ([String: Any]) -> Void
    let onPose: () async -> (pos: [Double], yaw: Double)?
    let onRemove: () -> Void

    /// Su giro actual (grados alrededor de z), que se pide al abrirlo y tras cada cambio.
    @State private var yaw: Double?
    @State private var color: Color
    @State private var colorTask: Task<Void, Never>?

    init(object: SceneObject, position: [Double], onUpdate: @escaping ([String: Any]) -> Void,
         onPose: @escaping () async -> (pos: [Double], yaw: Double)?, onRemove: @escaping () -> Void) {
        self.object = object
        self.position = position
        self.onUpdate = onUpdate
        self.onPose = onPose
        self.onRemove = onRemove
        _color = State(initialValue: Color(hex: object.displayColor))
    }

    var body: some View {
        let cm = Units.centimeters(position.count == 3 ? position : [0, 0, 0])
        let heavy = object.mass >= 1
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            line("Name") {
                TextCell(value: object.name, placeholder: SceneControls.label(object.shape)) { onUpdate(["name": $0]) }
            }
            line("Position", unit: "cm") {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(0..<3, id: \.self) { i in
                        NumberCell(prefix: ["x", "y", "z"][i], value: cm[i], digits: 1) { v in
                            var next = cm
                            next[i] = v
                            onUpdate(["pos": Units.meters(next)])
                            Task { await refreshYaw() }
                        }
                    }
                }
            }
            line("Rotation", unit: "°") {
                NumberCell(value: yaw ?? object.yaw, digits: 0) { v in
                    yaw = v
                    onUpdate(["yaw": v])
                }
                .frame(width: 70)
            }
            line("Mass", unit: heavy ? "kg" : "g") {
                NumberCell(value: heavy ? object.mass : object.mass * 1000, digits: heavy ? 2 : 0, min: heavy ? 0.001 : 1) { v in
                    onUpdate(["mass": heavy ? v : v / 1000])
                }
                .frame(width: 90)
            }
            line("Color") {
                ColorPicker("Color", selection: $color).labelsHidden()
            }
            line("Fixed in place") {
                Toggle("Fixed in place", isOn: Binding(get: { object.fixed }, set: { onUpdate(["fixed": $0]) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            HStack {
                Text("#\(object.id)").font(.caption).monospacedDigit().foregroundStyle(Theme.faint)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Label { Text("Remove") } icon: { Icon(name: .trash, size: 11) }
                }
                .controlSize(.small)
            }
        }
        .padding(.top, Theme.Space.xs)
        .task { await refreshYaw() }
        .onChange(of: color) { _, value in
            // El selector cambia sin parar mientras se arrastra: se aplica cuando se detiene.
            colorTask?.cancel()
            colorTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled, value.hex != object.displayColor { onUpdate(["color": value.hex]) }
            }
        }
    }

    private func refreshYaw() async {
        try? await Task.sleep(for: .milliseconds(100))   // que el motor aplique el cambio antes
        if let pose = await onPose() { yaw = pose.yaw }
    }

    private func line<C: View>(_ label: String, unit: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).font(.callout)
            if let unit { Text(unit).font(.caption).foregroundStyle(Theme.faint) }
            Spacer(minLength: Theme.Space.s)
            content()
        }
    }
}

/// Un número que se edita y se aplica con Enter o al salir del campo (Esc lo deja como estaba). Mientras no se
/// edita, muestra el valor en vivo.
private struct NumberCell: View {
    var prefix: String?
    let value: Double
    let digits: Int
    var min: Double?
    let onCommit: (Double) -> Void

    @State private var draft: String?
    @FocusState private var focused: Bool

    private var shown: String { value.isFinite ? String(format: "%.\(digits)f", value) : "0" }

    var body: some View {
        HStack(spacing: 3) {
            if let prefix { Text(prefix).font(.caption).foregroundStyle(Theme.faint) }
            TextField("", text: Binding(get: { draft ?? shown }, set: { draft = $0 }))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { draft = nil; focused = false }
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onChange(of: focused) { _, on in
            if on { draft = shown } else { commit() }
        }
    }

    private func commit() {
        guard let text = draft else { return }
        draft = nil
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")), v.isFinite,
              String(format: "%.\(digits)f", v) != shown else { return }
        onCommit(min.map { Swift.max($0, v) } ?? v)
    }
}

/// Un texto que se aplica con Enter o al salir del campo.
private struct TextCell: View {
    let value: String
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var draft: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(get: { draft ?? value }, set: { draft = $0 }))
            .textFieldStyle(.plain).multilineTextAlignment(.trailing).font(.callout)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, on in if !on { commit() } }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(maxWidth: 180)
    }

    private func commit() {
        guard let text = draft?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        draft = nil
        if text != value { onCommit(text) }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(text).font(.callout).monospacedDigit().foregroundStyle(Theme.muted)
            }
            Slider(value: $value, in: range).controlSize(.small).tint(Theme.ink.opacity(0.8))
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(s, radix: 16) ?? 0xCCCCCC
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
