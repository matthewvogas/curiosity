import SwiftUI

/// Panel flotante de vidrio sobre el escenario 3D, con pestañas arriba.
/// Lo de adentro va sin vidrio (nada de vidrio sobre vidrio) y con esquinas concéntricas.
struct FloatingPanel<Tab: Hashable, Content: View>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs, id: \.tab) { item in
                    TabButton(title: item.title, selected: selection == item.tab) {
                        withAnimation(.snappy(duration: 0.2)) { selection = item.tab }
                    }
                }
            }
            .padding(4)
            .background(Theme.fill, in: .capsule)
            .padding(.top, Theme.Space.m)
            .padding(.horizontal, Theme.Space.m)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.Radius.panel))
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.callout.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Theme.ink : Theme.muted)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
