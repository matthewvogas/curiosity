import SwiftUI

/// Acomoda vistas en mosaico. Cada una toma la forma de su imagen (sin franjas grises): la destacada lo más
/// grande posible y las demás chicas, en columna a la derecha o en fila abajo, según cuál deje más grande la
/// principal; el grupo queda centrado. Como es un Layout, cada vista conserva su identidad al cambiar de lugar
/// (el modelo 3D no se vuelve a cargar al destacarlo).
struct TileLayout: Layout {
    var focused: Int
    var spacing: CGFloat = 10
    /// La proporción (ancho/alto) de cada vista, en orden; 4:3 si falta.
    var aspects: [CGFloat] = []
    /// Cuánto ocupan las vistas chicas: fracción del ancho (en columna) o del alto (en fila). Se cambia arrastrando
    /// el divisor (`TileDivider`).
    var split: CGFloat = TileLayout.defaultSplit

    static let defaultSplit: CGFloat = 0.24
    static let splitRange: ClosedRange<CGFloat> = 0.12...0.6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let main = min(max(0, focused), subviews.count - 1)
        let ratios = subviews.indices.map { $0 < aspects.count && aspects[$0] > 0 ? aspects[$0] : 4 / 3 }
        let rects = Self.arrange(ratios, main: main, size: bounds.size, gap: spacing, split: split).rects
        for (i, r) in rects.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), proposal: ProposedViewSize(r.size))
        }
    }

    /// El rectángulo más grande con esa proporción que cabe en la caja, centrado en ella.
    static func fit(_ aspect: CGFloat, in box: CGRect) -> CGRect {
        let width = min(box.width, box.height * aspect), height = width / aspect
        return CGRect(x: box.minX + (box.width - width) / 2, y: box.minY + (box.height - height) / 2, width: width, height: height)
    }

    /// Dónde va cada vista y, si hay vistas chicas, dónde va el divisor (una línea vertical si están en columna,
    /// horizontal si están en fila).
    struct Arrangement {
        var rects: [CGRect]
        var column = true
        /// x del divisor (en columna) o y (en fila); nil con una sola vista.
        var divider: CGFloat?
    }

    static func arrange(_ aspects: [CGFloat], main: Int, size: CGSize, gap: CGFloat, split: CGFloat = defaultSplit) -> Arrangement {
        let n = aspects.count, W = size.width, H = size.height
        guard n > 0, W > 0, H > 0 else { return Arrangement(rects: Array(repeating: .zero, count: n)) }
        if n == 1 { return Arrangement(rects: [fit(aspects[0], in: CGRect(origin: .zero, size: size))]) }
        let split = min(max(split, splitRange.lowerBound), splitRange.upperBound)
        let others = aspects.indices.filter { $0 != main }
        let gaps = gap * CGFloat(others.count - 1)

        // A: columna a la derecha.
        let side = max(W * split, 120)
        let colMain = fit(aspects[main], in: CGRect(x: 0, y: 0, width: W - side - gap, height: H))
        var heights = others.map { side / aspects[$0] }
        let colTotal = heights.reduce(0, +) + gaps
        if colTotal > H { heights = heights.map { $0 * (H - gaps) / (colTotal - gaps) } }
        var col = Array(repeating: CGRect.zero, count: n)
        var y = max(0, colMain.minY + (colMain.height - min(colTotal, H)) / 2)
        for (k, i) in others.enumerated() {
            col[i] = CGRect(x: colMain.maxX + gap, y: y, width: heights[k] * aspects[i], height: heights[k])
            y += heights[k] + gap
        }
        col[main] = colMain

        // B: fila abajo.
        let strip = max(H * split, 80)
        let rowMain = fit(aspects[main], in: CGRect(x: 0, y: 0, width: W, height: H - strip - gap))
        var widths = others.map { strip * aspects[$0] }
        let rowTotal = widths.reduce(0, +) + gaps
        if rowTotal > W { widths = widths.map { $0 * (W - gaps) / (rowTotal - gaps) } }
        var row = Array(repeating: CGRect.zero, count: n)
        var x = (W - min(rowTotal, W)) / 2
        for (k, i) in others.enumerated() {
            row[i] = CGRect(x: x, y: rowMain.maxY + gap, width: widths[k], height: widths[k] / aspects[i])
            x += widths[k] + gap
        }
        row[main] = rowMain

        let column = colMain.width * colMain.height >= rowMain.width * rowMain.height
        let rects = column ? col : row
        // Todo el grupo centrado en el espacio disponible.
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let dx = (W - union.width) / 2 - union.minX, dy = (H - union.height) / 2 - union.minY
        let placed = rects.map { $0.offsetBy(dx: dx, dy: dy) }
        let divider = column ? placed[main].maxX + gap / 2 : placed[main].maxY + gap / 2
        return Arrangement(rects: placed, column: column, divider: divider)
    }

    /// La fracción para las vistas chicas que deja el divisor en `position` (x en columna, y en fila).
    static func split(at position: CGFloat, column: Bool, size: CGSize) -> CGFloat {
        let total = column ? size.width : size.height
        guard total > 0 else { return defaultSplit }
        return min(max((total - position) / total, splitRange.lowerBound), splitRange.upperBound)
    }
}

/// El divisor entre la vista grande y las chicas: se arrastra para cambiar cuánto ocupa cada parte; doble clic
/// vuelve al tamaño de siempre.
struct TileDivider: View {
    let arrangement: TileLayout.Arrangement
    let size: CGSize
    @Binding var split: Double
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        if let at = arrangement.divider {
            let column = arrangement.column
            Capsule()
                .fill(Color.primary.opacity(dragging ? 0.5 : hovering ? 0.32 : 0))
                .frame(width: column ? 4 : 48, height: column ? 48 : 4)
                .frame(width: column ? 14 : size.width, height: column ? size.height : 14)
                .contentShape(.rect)
                .position(x: column ? at : size.width / 2, y: column ? size.height / 2 : at)
                .onHover { inside in
                    hovering = inside
                    if inside { (column ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("tiles"))
                    .onChanged { g in
                        dragging = true
                        split = Double(TileLayout.split(at: column ? g.location.x : g.location.y, column: column, size: size))
                    }
                    .onEnded { _ in dragging = false })
                .onTapGesture(count: 2) { withAnimation(.snappy) { split = Double(TileLayout.defaultSplit) } }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .help("Drag to resize · double-click to reset")
        }
    }
}

/// Un panel del mosaico: su contenido en un contenedor redondeado, con su nombre.
struct Tile<Content: View>: View {
    let title: String
    let focused: Bool
    let onTap: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Theme.fill
            content
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
        .overlay(alignment: .topLeading) {
            Text(title).font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(.regular, in: .capsule)
                .padding(Theme.Space.s)
        }
        .overlay {
            // En los paneles chicos, un clic lo pasa a grande (el 3D grande se sigue pudiendo girar).
            if !focused { Color.clear.contentShape(.rect).onTapGesture(perform: onTap) }
        }
        .help(focused ? "" : "View large")
    }
}
