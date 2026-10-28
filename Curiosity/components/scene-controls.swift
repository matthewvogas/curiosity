import SwiftUI

/// Escena: los objetos y agregar uno nuevo.
struct SceneControls: View {
    let objects: [SceneObject]
    let onAdd: (SceneObject) -> Void
    let onRemove: (Int) -> Void

    @State private var shape = "box"
    @State private var sizeCM = 3.0
    @State private var massG = 20.0
    @State private var color = Color(red: 0.89, green: 0.34, blue: 0.18)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                section("Objetos") {
                    if objects.isEmpty {
                        Text("No hay objetos. Agrega uno abajo o pídeselo a la IA.").font(.callout).foregroundStyle(Theme.muted)
                    }
                    ForEach(objects) { o in
                        HStack(spacing: Theme.Space.s) {
                            Circle().fill(Color(hex: o.color)).frame(width: 10, height: 10)
                            Text(Self.label(o.shape)).font(.callout)
                            Text(o.size.map { String(format: "%.1f", $0 * 100) }.joined(separator: "×") + " cm")
                                .font(.caption).foregroundStyle(Theme.muted)
                            Spacer()
                            Text("#\(o.id)").font(.caption).monospacedDigit().foregroundStyle(Theme.faint)
                            Button { onRemove(o.id) } label: { Icon(name: .trash, size: 11) }
                                .buttonStyle(.borderless).foregroundStyle(Theme.muted)
                        }
                    }
                }

                section("Agregar") {
                    Picker("Forma", selection: $shape) {
                        Text("Caja").tag("box"); Text("Esfera").tag("sphere"); Text("Cilindro").tag("cylinder")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    LabeledSlider(title: "Tamaño", value: $sizeCM, range: 1...10, format: "%.1f cm")
                    LabeledSlider(title: "Masa", value: $massG, range: 1...500, format: "%.0f g")
                    HStack {
                        ColorPicker("Color", selection: $color).font(.callout)
                        Spacer()
                        Button("Soltar en la mesa") { onAdd(newObject) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    private var newObject: SceneObject {
        let s = sizeCM / 100
        let size: [Double] = shape == "sphere" ? [s / 2] : shape == "cylinder" ? [s / 2, s] : [s, s, s]
        return SceneObject(id: 0, shape: shape, size: size, mass: massG / 1000, color: color.hex,
                           pos: [Double.random(in: 0.15...0.25), Double.random(in: -0.1...0.1), 0.12])
    }

    private static func label(_ shape: String) -> String {
        switch shape { case "sphere": "Esfera"; case "cylinder": "Cilindro"; default: "Caja" }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).font(.headline)
            content()
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value)).font(.callout).monospacedDigit().foregroundStyle(Theme.muted)
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
