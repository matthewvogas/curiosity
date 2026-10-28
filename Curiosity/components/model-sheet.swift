import SwiftUI

/// Hoja con el resumen del modelo en texto (el «Print model» de MuJoCo), con opción de copiarlo.
struct ModelSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.l)
            ScrollView {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.l)
            }
            .background(Theme.fill)
        }
        .frame(width: 620, height: 520)
    }
}
