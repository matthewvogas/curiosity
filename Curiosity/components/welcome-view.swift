import SwiftUI

/// La pantalla de inicio cuando no hay nada abierto: simular un robot o conectar uno real.
struct WelcomeView: View {
    let onOpenSimulator: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            VStack(spacing: Theme.Space.s) {
                Image("Logo")
                    .resizable()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(Theme.ink)
                Text("Curiosity").font(.largeTitle.weight(.bold))
            }
            HStack(spacing: Theme.Space.m) {
                StartCard(icon: .robot, title: "Open simulator",
                          detail: "Physics simulation with AI",
                          action: onOpenSimulator)
                StartCard(icon: .link, title: "Connect external robot",
                          detail: "Over USB",
                          action: onConnect)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StartCard: View {
    let icon: IconName
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Icon(name: icon, size: 22)
                    .frame(width: 44, height: 44)
                    .background(Theme.fill, in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 260, alignment: .leading)
            .frame(minHeight: 160, alignment: .topLeading)
            .background(hovering ? Theme.selection : Theme.fill.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.card + 4))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card + 4).strokeBorder(Theme.hairline))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
