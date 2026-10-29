import AppKit
import Observation
import SwiftUI

/// La página de notas de una tarea, como un documento: una tarjeta como las secciones de la página de pasos, con
/// una barra pequeña (título, negrita, cursiva, lista). Se guarda sola en cada cambio.
struct NotePage: View {
    let url: URL
    @State private var editor = NoteEditor()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tool("Heading", "textformat.size", "h", editor.toggleHeading)
                tool("Bold", "bold", "b", editor.toggleBold)
                tool("Italic", "italic", "i", editor.toggleItalic)
                tool("List", "list.bullet", "l", editor.toggleList)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.xs).padding(.vertical, Theme.Space.xs)
            Divider().overlay(Theme.hairline).padding(.horizontal, Theme.Space.s)
            NoteText(url: url, editor: editor)
        }
        .background(Theme.fill, in: .rect(cornerRadius: Self.radius))
        .padding(.horizontal, Theme.Space.xl).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xl)
    }

    /// Las esquinas de las secciones del Form agrupado.
    private static let radius: CGFloat = 10

    private func tool(_ name: String, _ icon: String, _ key: KeyEquivalent, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 28, height: 24).contentShape(.rect) }
            .buttonStyle(.borderless)
            .keyboardShortcut(key, modifiers: key == "h" || key == "l" ? [.command, .shift] : .command)
            .help(name)
    }
}

/// Las acciones de formato sobre el texto abierto (deshacer incluido, y se guardan como cualquier cambio).
@Observable
final class NoteEditor {
    @ObservationIgnored weak var textView: NSTextView?

    /// Los tamaños del Form (13 pt) para el texto; los títulos, como los de sección pero un poco más grandes.
    static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let heading = NSFont.systemFont(ofSize: 17, weight: .semibold)
    private static let bullet = "•\t"

    func toggleBold() { toggle(.boldFontMask) }
    func toggleItalic() { toggle(.italicFontMask) }

    /// Negrita o cursiva en la selección (o en lo que se escriba a continuación).
    private func toggle(_ trait: NSFontTraitMask) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fonts = NSFontManager.shared
        let range = tv.selectedRange()
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? Self.body
            let on = fonts.traits(of: font).contains(trait)
            tv.typingAttributes[.font] = on ? fonts.convert(font, toNotHaveTrait: trait) : fonts.convert(font, toHaveTrait: trait)
            return
        }
        var allOn = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if !fonts.traits(of: value as? NSFont ?? Self.body).contains(trait) { allOn = false }
        }
        edit(range) { storage in
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? Self.body
                storage.addAttribute(.font, value: allOn ? fonts.convert(font, toNotHaveTrait: trait) : fonts.convert(font, toHaveTrait: trait), range: sub)
            }
        }
    }

    /// El párrafo como título, o de vuelta a texto normal.
    func toggleHeading() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        let current = range.length > 0 ? storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : tv.typingAttributes[.font] as? NSFont
        let font = (current?.pointSize ?? Self.body.pointSize) > Self.body.pointSize ? Self.body : Self.heading
        if range.length == 0 { tv.typingAttributes[.font] = font; return }
        edit(range) { $0.addAttribute(.font, value: font, range: range) }
    }

    /// Viñetas al principio de cada línea seleccionada, o las quita si ya están.
    func toggleList() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = tv.string as NSString
        let range = text.paragraphRange(for: tv.selectedRange())
        var starts: [Int] = []
        text.enumerateSubstrings(in: range, options: .byParagraphs) { _, sub, _, _ in starts.append(sub.location) }
        if starts.isEmpty { starts = [range.location] }
        let allListed = starts.allSatisfy { text.length >= $0 + Self.bullet.count && text.substring(with: NSRange(location: $0, length: Self.bullet.count)) == Self.bullet }
        edit(range) { storage in
            for start in starts.reversed() {
                if allListed {
                    storage.deleteCharacters(in: NSRange(location: start, length: Self.bullet.count))
                } else {
                    let attributes = start < storage.length ? storage.attributes(at: start, effectiveRange: nil) : tv.typingAttributes
                    storage.insert(NSAttributedString(string: Self.bullet, attributes: attributes), at: start)
                }
            }
        }
    }

    /// Un cambio que se puede deshacer y que avisa (para guardarse).
    private func edit(_ range: NSRange, _ change: (NSTextStorage) -> Void) {
        guard let tv = textView, let storage = tv.textStorage, tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        change(storage)
        storage.endEditing()
        tv.didChangeText()
    }
}

/// El texto con formato (AppKit), sin fondo propio: usa el de la tarjeta.
private struct NoteText: NSViewRepresentable {
    let url: URL
    let editor: NoteEditor

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay   // como el resto de la app: la barra solo aparece al desplazar
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.drawsBackground = false
        text.isRichText = true
        text.allowsUndo = true
        text.usesFindBar = true
        text.usesAdaptiveColorMappingForDarkAppearance = true   // el texto negro del archivo se ve claro en modo oscuro
        text.textContainerInset = NSSize(width: Theme.Space.s, height: Theme.Space.m)
        text.typingAttributes = [.font: NoteEditor.body]
        text.delegate = context.coordinator
        context.coordinator.load(into: text)
        editor.textView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Otra tarea: guarda la anterior y abre la suya.
        guard context.coordinator.url != url, let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.save(text)
        context.coordinator.url = url
        context.coordinator.load(into: text)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let text = scroll.documentView as? NSTextView { coordinator.save(text) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var url: URL

        init(url: URL) { self.url = url }

        func load(into text: NSTextView) {
            text.textStorage?.setAttributedString(NoteQueries.load(url))
            text.undoManager?.removeAllActions()
        }

        func save(_ text: NSTextView) { NoteQueries.save(text.attributedString(), to: url) }

        func textDidChange(_ notification: Notification) {
            if let text = notification.object as? NSTextView { save(text) }
        }
    }
}
