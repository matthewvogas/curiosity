import SwiftUI

/// Tarjeta de una opción (agregar robot, proveedor de IA): ícono, título, descripción y estado.
struct OptionCard: View {
    let icon: IconName
    let title: String
    let detail: String
    var badge: String? = nil
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Icon(name: icon, size: 18)
                    .frame(width: 36, height: 36)
                    .background(Theme.fill, in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.body.weight(.semibold))
                        if let badge {
                            Text(badge).font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.fill, in: .capsule)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    Text(detail).font(.callout).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && enabled ? Theme.selection : Theme.fill.opacity(0.5), in: .rect(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
            .contentShape(.rect)
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
