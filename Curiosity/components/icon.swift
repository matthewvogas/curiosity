import SwiftUI

/// Todos los íconos de la app, en un solo lugar (SF Symbols, nativos de Apple).
enum IconName: String {
    case robot = "cube.transparent"
    case robotFill = "cube.transparent.fill"
    case add = "plus"
    case play = "play.fill"
    case pause = "pause.fill"
    case step = "forward.frame.fill"
    case reset = "arrow.counterclockwise"
    case speed = "gauge.with.dots.needle.33percent"
    case camera = "camera"
    case views = "rotate.3d"
    case send = "arrow.up"
    case stop = "stop.fill"
    case sparkles = "sparkles"
    case key = "key"
    case settings = "gearshape"
    case file = "doc.badge.plus"
    case link = "cable.connector"
    case globe = "globe"
    case check = "checkmark.circle.fill"
    case warning = "exclamationmark.triangle.fill"
    case eye = "eye"
    case move = "arrow.up.and.down.and.arrow.left.and.right"
    case object = "shippingbox"
    case trash = "trash"
    case sliders = "slider.horizontal.3"
    case chat = "bubble.left.and.text.bubble.right"
    case scene = "square.3.layers.3d"
    case gauge = "dial.medium"
    case info = "info.circle"
    case chevron = "chevron.right"
    case clear = "square.and.pencil"
    case task = "circle.dashed"
    case taskTraining = "circle.lefthalf.filled"
    case taskLearned = "checkmark.circle"
    case dataset = "film.stack"
    case model = "brain"
    case more = "ellipsis.circle"
}

/// `<Icon name: size:>`: nada de nombres de símbolos sueltos por la app.
struct Icon: View {
    let name: IconName
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: name.rawValue)
            .font(.system(size: size, weight: weight))
    }
}
