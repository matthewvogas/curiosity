import SwiftUI

/// Un robot físico conectado: su nombre y qué motores respondieron.
/// Solo dibuja: datos y acciones llegan por props.
struct HardwareTestView: View {
    let port: String
    @Binding var name: String
    let placeholder: String
    let connected: Bool
    let testing: Bool
    let progress: Double
    let result: String?
    let resultIsError: Bool
    let found: [FoundMotor]
    let onTest: () -> Void

    var body: some View {
        Group {
            Section {
                TextField("Name", text: $name, prompt: Text(placeholder))
                LabeledContent("Port", value: port.replacingOccurrences(of: "/dev/", with: ""))
                if !found.isEmpty {
                    // Lo que respondió de verdad en la última prueba, no lo que se supone.
                    LabeledContent("Motors", value: Dictionary(grouping: found, by: \.modelName)
                        .map { "\($0.value.count) × \($0.key)" }.sorted().joined(separator: " · "))
                }
            }
            .disabled(testing)

            Section {
                HStack {
                    if testing {
                        ProgressView(value: progress).frame(width: 140)
                        Text("Looking for motors…").foregroundStyle(Theme.muted)
                    } else if let result {
                        Circle().fill(resultIsError ? Theme.red : found.isEmpty ? Theme.yellow : Theme.green).frame(width: 8, height: 8)
                        Text(result).foregroundStyle(resultIsError ? Theme.red : Theme.ink)
                    } else if !connected {
                        Circle().fill(Theme.faint).frame(width: 8, height: 8)
                        Text("Unplugged").foregroundStyle(Theme.muted)
                    } else {
                        Text("Not tested").foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Test", action: onTest).buttonStyle(.borderedProminent).disabled(testing || !connected)
                }
                ForEach(found) { m in
                    HStack {
                        Text("ID \(m.id)").monospacedDigit().frame(width: 60, alignment: .leading)
                        Text(m.modelName).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(m.position.map { "position \($0)" } ?? "").monospacedDigit().foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}
