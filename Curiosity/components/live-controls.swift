import SwiftUI

/// Control manual del robot real: un deslizador por articulación (a dónde va) con dónde está de verdad.
/// El robot va despacio hacia lo que marques. Solo dibuja: datos y acciones por props.
struct LiveControls: View {
    let joints: [String]
    let positions: [String: Double]
    let targets: [String: Double]
    let limits: [String: ClosedRange<Double>]
    let onChange: (String, Double) -> Void
    let onHome: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text("Control").font(.headline)
                    Spacer()
                    Button("Pose del principio", action: onHome).buttonStyle(.link)
                        .help("Vuelve despacio a la pose en que estaba al conectarlo")
                }
                Text("El robot va despacio hacia donde marques.").font(.caption).foregroundStyle(Theme.muted)
                ForEach(joints, id: \.self) { j in
                    if let range = limits[j] {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(j).lineLimit(1)
                                Spacer()
                                Text(RealAgentTools.format(positions[j] ?? 0, j)).monospacedDigit().foregroundStyle(Theme.muted)
                                    .help("Dónde está ahora")
                            }
                            Slider(value: Binding(get: { targets[j] ?? 0 }, set: { onChange(j, $0) }), in: range)
                                .controlSize(.small)
                                .tint(Theme.ink.opacity(0.8))
                        }
                    }
                }
            }
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }
}
