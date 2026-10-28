import SwiftUI

/// Tokens de diseño. Neutros sin color de marca; el vidrio (Liquid Glass) solo en la capa de controles.
///
/// Reglas de Liquid Glass (Apple HIG, macOS 26):
///  · Vidrio para lo que flota sobre el contenido: barra lateral, toolbar, panel de chat, controles.
///  · Nunca vidrio sobre vidrio; dentro de un panel de vidrio, rellenos sutiles.
///  · Tinte solo en la acción principal o en un estado importante.
///  · Esquinas concéntricas: un elemento dentro de otro resta su margen al radio del contenedor.
enum Theme {
    // Texto
    static let ink = Color.primary
    static let muted = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)

    // Rellenos sutiles (dentro de paneles de vidrio o sobre el contenido)
    /// Fila seleccionada o hover: apenas se nota (≈6 %), como WhatsApp y Mail.
    static let selection = Color.primary.opacity(0.06)
    static let hover = Color.primary.opacity(0.04)
    static let fill = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)

    // Estados
    static let red = Color(red: 0.92, green: 0.34, blue: 0.34)
    static let green = Color(red: 0.20, green: 0.74, blue: 0.45)
    static let yellow = Color(red: 0.95, green: 0.79, blue: 0.30)
    static let blue = Color(red: 0.31, green: 0.65, blue: 0.99)

    /// Fondo del escenario 3D: un estudio claro, o grafito en modo oscuro.
    static let stage = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(srgbRed: 0.91, green: 0.91, blue: 0.90, alpha: 1)
    })

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20, xxl: CGFloat = 28
    }

    enum Radius {
        /// Panel flotante (chat). Los elementos de adentro usan `panel - margen` (concéntricos).
        static let panel: CGFloat = 26
        static let card: CGFloat = 14
        static let row: CGFloat = 8
    }

    static let chatWidth: CGFloat = 400
}
