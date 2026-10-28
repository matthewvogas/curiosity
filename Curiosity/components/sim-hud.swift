import SwiftUI

/// Indicador flotante de la simulación: tiempo, velocidad real y contactos. Control flotante → vidrio.
struct SimHUD: View {
    let time: Double
    let realTimeFactor: Double
    let contacts: Int
    let paused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(spacing: 6) {
                Circle().fill(paused ? Theme.yellow : Theme.green).frame(width: 7, height: 7)
                Text(paused ? "Paused" : "Running").font(.caption.weight(.semibold))
            }
            Text(String(format: "%.1f s", time)).monospacedDigit()
            Text(String(format: "%.2f×", realTimeFactor)).monospacedDigit().help("Speed relative to real time")
            Text("\(contacts) contacts").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(Theme.ink.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Mensaje centrado sobre el escenario (cargando o error).
struct StageMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if isError { Icon(name: .warning, size: 13).foregroundStyle(Theme.red) } else { ProgressView().controlSize(.small) }
            Text(text).font(.callout)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .glassEffect(.regular, in: .capsule)
    }
}
