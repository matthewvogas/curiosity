import SwiftUI

/// Un robot físico conectado: su nombre, tipo de motores, velocidad y qué motores respondieron.
/// Solo dibuja: datos y acciones llegan por props.
struct HardwareTestView: View {
    let port: String
    @Binding var name: String
    let placeholder: String
    @Binding var bus: BusProtocol
    @Binding var baud: Int
    let testing: Bool
    let progress: Double
    let result: String?
    let resultIsError: Bool
    let found: [FoundMotor]
    let onTest: () -> Void

    private static let bauds = [57_600, 115_200, 500_000, 1_000_000, 2_000_000, 3_000_000]

    var body: some View {
        Form {
            Section {
                TextField("Nombre", text: $name, prompt: Text(placeholder))
                LabeledContent("Puerto", value: port.replacingOccurrences(of: "/dev/", with: ""))
                Picker("Motores", selection: $bus) {
                    ForEach(BusProtocol.allCases) { b in Text("\(b.name) · \(b.example)").tag(b) }
                }
                Picker("Velocidad", selection: $baud) {
                    ForEach(Self.bauds, id: \.self) { Text("\($0.formatted()) baudios").tag($0) }
                }
            } footer: {
                Text("«Probar» abre el puerto, busca qué motores responden y lo cierra: solo lee, no mueve nada. Si LeRobot está usando este puerto, ciérralo primero.")
                    .foregroundStyle(Theme.muted)
            }
            .disabled(testing)

            Section {
                HStack {
                    if testing {
                        ProgressView(value: progress).frame(width: 140)
                        Text("Buscando motores…").foregroundStyle(Theme.muted)
                    } else if let result {
                        Circle().fill(resultIsError ? Theme.red : found.isEmpty ? Theme.yellow : Theme.green).frame(width: 8, height: 8)
                        Text(result).foregroundStyle(resultIsError ? Theme.red : Theme.ink)
                    } else {
                        Text("Sin probar").foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Probar", action: onTest).buttonStyle(.borderedProminent).disabled(testing)
                }
                ForEach(found) { m in
                    HStack {
                        Text("ID \(m.id)").monospacedDigit().frame(width: 60, alignment: .leading)
                        Text(m.modelName).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(m.position.map { "posición \($0)" } ?? "").monospacedDigit().foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
