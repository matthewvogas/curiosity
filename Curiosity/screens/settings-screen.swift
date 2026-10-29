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
                                Text("Key saved").foregroundStyle(Theme.muted)
                            }
                            Button("Test") { Task { await settings.testConnection() } }
                            Button("Remove", role: .destructive) { settings.removeAnthropicKey() }
                        }
                    }
                } else {
                    LabeledContent("Anthropic") {
                        HStack {
                            SecureField("sk-ant-…", text: $keyDraft).frame(minWidth: 220)
                            Button("Save") { settings.saveAnthropicKey(keyDraft); keyDraft = "" }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                Picker("Model", selection: $settings.modelID) {
                    ForEach(AIModel.all) { m in Text(m.name).tag(m.id) }
                }
                Picker("Thinking effort", selection: $settings.effort) {
                    Text("Low (faster)").tag("low")
                    Text("Normal").tag("medium")
                    Text("High (hard tasks)").tag("high")
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Stored in your Keychain.")
                    .foregroundStyle(Theme.muted)
            }

            Section {
                TextField("LeRobot Python", text: $settings.lerobotPython)
                LabeledContent("Hugging Face") {
                    if settings.hasHubToken {
                        HStack {
                            Text("Token saved").foregroundStyle(Theme.muted)
                            Button("Remove", role: .destructive) { settings.removeHubToken() }
                        }
                    } else {
                        HStack {
                            SecureField("hf_…", text: $hubDraft).frame(minWidth: 220)
                            Button("Save") { settings.saveHubToken(hubDraft); hubDraft = "" }
                                .disabled(hubDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            } header: {
                Text("Connected robots")
            } footer: {
                Text("Hugging Face token needs write access. Stored in your Keychain.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

