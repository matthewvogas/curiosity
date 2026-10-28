import SwiftUI

/// Acomoda vistas en mosaico: una sola llena todo; con varias, la destacada va grande a la izquierda y las
/// demás en columna a la derecha. Como es un Layout, cada vista conserva su identidad al cambiar de lugar
/// (el modelo 3D no se vuelve a cargar al destacarlo).
struct TileLayout: Layout {
    var focused: Int
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 800, height: 600))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let main = min(max(0, focused), subviews.count - 1)
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let side = min(bounds.width * 0.28, 280)
        let mainRect = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width - side - spacing, height: bounds.height)
        subviews[main].place(at: mainRect.origin, proposal: ProposedViewSize(mainRect.size))
        let others = subviews.indices.filter { $0 != main }
        let tileHeight = min(side * 3 / 4, (bounds.height - spacing * CGFloat(others.count - 1)) / CGFloat(others.count))
        for (n, i) in others.enumerated() {
            let origin = CGPoint(x: mainRect.maxX + spacing, y: bounds.minY + CGFloat(n) * (tileHeight + spacing))
            subviews[i].place(at: origin, proposal: ProposedViewSize(width: side, height: tileHeight))
        }
    }
}
