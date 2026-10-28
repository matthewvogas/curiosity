import SwiftUI

/// Ajustes: conectar modelos de IA con su API key (guardada en el Llavero) y elegir el modelo.
struct SettingsScreen: View {
    @Environment(UseSettings.self) private var settings
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                if settings.hasAnthropicKey {
                    LabeledContent("Anthropic") {
                        HStack(spacing: Theme.Space.s) {
                            if settings.testing { ProgressView().controlSize(.small) }
                            else if let r = settings.testResult {
                                Label(r.message, systemImage: (r.ok ? IconName.check : IconName.warning).rawValue)
                                    .foregroundStyle(r.ok ? Theme.green : Theme.red).lineLimit(2)
                            } else {
                                Text("Key guardada").foregroundStyle(Theme.muted)
                            }
                            Button("Probar") { Task { await settings.testConnection() } }
                            Button("Quitar", role: .destructive) { settings.removeAnthropicKey() }
                        }
                    }
                } else {
                    LabeledContent("Anthropic") {
                        HStack {
                            SecureField("sk-ant-…", text: $keyDraft).frame(minWidth: 220)
                            Button("Guardar") { settings.saveAnthropicKey(keyDraft); keyDraft = "" }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Picker("Modelo", selection: $settings.modelID) {
                    ForEach(AIModel.all) { m in Text(m.name).tag(m.id) }
                }
                Picker("Cuánto piensa", selection: $settings.effort) {
                    Text("Poco (más rápido)").tag("low")
                    Text("Normal").tag("medium")
                    Text("Mucho (tareas difíciles)").tag("high")
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("La key se guarda en el Llavero de tu Mac y solo se envía a api.anthropic.com. Consíguela en console.anthropic.com.")
                    .foregroundStyle(Theme.muted)
            }

            Section("Próximamente") {
                ProviderRow(name: "OpenAI", detail: "GPT para conversar y planear")
                ProviderRow(name: "Google Gemini", detail: "Gemini Robotics")
                ProviderRow(name: "Hugging Face", detail: "Modelos de robots: SmolVLA, π0, GR00T")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderRow: View {
    let name: String
    let detail: String

    var body: some View {
        LabeledContent {
            Text("Pronto").foregroundStyle(Theme.faint)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}
