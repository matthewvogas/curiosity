import SwiftUI

/// Probar la conexión con el robot físico: puerto, tipo de motores, velocidad y qué motores respondieron.
/// Solo dibuja: datos y acciones llegan por props.
struct HardwareTestView: View {
    let ports: [String]
    @Binding var port: String?
    @Binding var bus: BusProtocol
    @Binding var baud: Int
    let testing: Bool
    let progress: Double
    let result: String?
    let resultIsError: Bool
    let found: [FoundMotor]
    let onRefresh: () -> Void
    let onTest: () -> Void

    private static let bauds = [57_600, 115_200, 500_000, 1_000_000, 2_000_000, 3_000_000]

    var body: some View {
        Form {
            Section {
                Picker("Puerto", selection: $port) {
                    if ports.isEmpty { Text("No hay ningún adaptador USB").tag(String?.none) }
                    ForEach(ports, id: \.self) { Text($0.replacingOccurrences(of: "/dev/", with: "")).tag(String?.some($0)) }
                }
                Picker("Motores", selection: $bus) {
                    ForEach(BusProtocol.allCases) { b in Text("\(b.name) · \(b.example)").tag(b) }
                }
                Picker("Velocidad", selection: $baud) {
                    ForEach(Self.bauds, id: \.self) { Text("\($0.formatted()) baudios").tag($0) }
                }
            } footer: {
                Text("Conecta el robot por USB y su fuente de poder. La prueba solo lee: no mueve nada. Si LeRobot está usando el puerto, ciérralo primero.")
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
                    Button("Actualizar puertos", action: onRefresh).disabled(testing)
                    Button("Probar", action: onTest).buttonStyle(.borderedProminent).disabled(testing || port == nil)
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
