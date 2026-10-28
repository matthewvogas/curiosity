import SwiftUI

/// Ajustes: conectar modelos de IA con su API key (guardada en el Llavero) y elegir el modelo.
struct SettingsScreen: View {
    @Environment(UseSettings.self) private var settings
    @State private var keyDraft = ""
    @State private var hubDraft = ""

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

            Section {
                TextField("Python de LeRobot", text: $settings.lerobotPython)
                LabeledContent("Hugging Face") {
                    if settings.hasHubToken {
                        HStack {
                            Text("Token guardado").foregroundStyle(Theme.muted)
                            Button("Quitar", role: .destructive) { settings.removeHubToken() }
                        }
                    } else {
                        HStack {
                            SecureField("hf_…", text: $hubDraft).frame(minWidth: 220)
                            Button("Guardar") { settings.saveHubToken(hubDraft); hubDraft = "" }
                                .disabled(hubDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } header: {
                Text("Robots conectados")
            } footer: {
                Text("Para teleoperar, grabar y entrenar, la app usa tu instalación de LeRobot. El token de Hugging Face (huggingface.co/settings/tokens, con permiso de escritura) sirve para subir datasets y bajar los privados; se guarda en el Llavero.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

