import SwiftUI
import Charts

/// Un entrenamiento en vivo: en qué va, cuánto falta, la curva de la pérdida y lo último del registro.
/// Solo dibuja: datos y acciones por props.
struct TrainingLiveView: View {
    let title: String
    let detail: String
    let progress: TrainProgress?
    let watch: TrainWatch?
    let onStop: (() -> Void)?
    let onClose: () -> Void

    private var running: Bool { progress?.running == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(Theme.muted)
                }
                Spacer()
                Label(status, systemImage: running ? "circle.fill" : progress?.hasModel == true ? "checkmark.circle.fill" : "pause.circle")
                    .font(.callout).foregroundStyle(running ? Theme.ink : Theme.muted)
            }

            if let p = progress, let total = p.total {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p.fraction)
                    HStack {
                        Text("Paso \(p.step.formatted()) de \(total.formatted())")
                        Spacer()
                        if let e = p.elapsed { Text("Lleva \(e)") }
                        if running, let r = p.remaining { Text("· faltan \(r)") }
                    }
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text("Pérdida").font(.headline)
                    Spacer()
                    if let loss = watch?.history.last?.loss ?? progress?.loss {
                        Text(String(format: "%.3f", loss)).font(.headline.monospacedDigit())
                    }
                }
                if let points = watch?.history, points.count > 1 {
                    Chart(points) { p in
                        LineMark(x: .value("Paso", p.step), y: .value("Pérdida", p.loss))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Theme.ink.opacity(0.85))
                    }
                    .chartYScale(type: .log)
                    .chartXAxisLabel("paso")
                    .frame(height: 180)
                } else {
                    Text("La curva aparece con los primeros registros (cada 200 pasos).")
                        .font(.callout).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                Text("Más baja es mejor; que se aplane indica que ya aprendió lo que podía de esos datos.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Registro").font(.headline)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array((watch?.log ?? []).enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.tail).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .onChange(of: watch?.log.count) { proxy.scrollTo((watch?.log.count ?? 1) - 1, anchor: .bottom) }
                }
                .padding(Theme.Space.s)
                .frame(height: 150)
                .background(Theme.fill, in: .rect(cornerRadius: 10))
            }

            HStack {
                if running, let onStop { Button("Detener entrenamiento", role: .destructive, action: onStop) }
                Spacer()
                Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 640)
    }

    private var status: String {
        if running { return "Entrenando" }
        if progress?.hasModel == true { return "Terminado" }
        if progress?.error != nil { return "Se detuvo" }
        return "Detenido"
    }
}
