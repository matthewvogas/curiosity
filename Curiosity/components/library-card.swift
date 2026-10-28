import SwiftUI

/// Un robot de la biblioteca: vista previa, nombre, tipo y el botón para agregarlo.
struct LibraryCard: View {
    let name: String
    let category: String
    let imageURL: URL?
    let added: Bool
    /// nil = no se está descargando; 0…1 = progreso.
    let progress: Double?
    let onAdd: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else {
                    Icon(name: .robot, size: 28).foregroundStyle(Theme.faint)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(Theme.fill, in: .rect(cornerRadius: Theme.Radius.card - 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                Text(category).font(.caption).foregroundStyle(Theme.muted)
            }

            Group {
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                } else if added {
                    Text("In my robots").font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                } else {
                    Button("Add", action: onAdd).buttonStyle(.link).font(.callout.weight(.medium))
                }
            }
            .frame(height: 18, alignment: .leading)
        }
        .padding(Theme.Space.s)
        .background(hovering ? Theme.selection : .clear, in: .rect(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { if !added && progress == nil { onAdd() } }
    }
}
