import SwiftUI

// Ajustes del robot real. Solo dibujan: datos y acciones llegan por props.

/// Cómo se arma el robot: calibraciones de LeRobot, el leader y la cámara.
struct RobotSetupView: View {
    let followers: [String]
    let leaders: [String]
    let otherPorts: [String]
    let cameras: [CameraInfo]
    @Binding var followerID: String?
    @Binding var leaderPort: String?
    @Binding var leaderID: String?
    @Binding var cameraIndex: Int?
    @Binding var extraCameras: [Int]
    let snapshot: Data?
    let onSnapshot: () -> Void

    var body: some View {
        Section {
            Picker("Calibración del follower", selection: $followerID) {
                Text("Elige…").tag(String?.none)
                ForEach(followers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Puerto del leader", selection: $leaderPort) {
                Text("Sin leader").tag(String?.none)
                ForEach(otherPorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag(String?.some($0)) }
            }
            Picker("Calibración del leader", selection: $leaderID) {
                Text("Elige…").tag(String?.none)
                ForEach(leaders, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .disabled(leaderPort == nil)
            HStack {
                Picker("Cámara", selection: $cameraIndex) {
                    Text("Elige…").tag(Int?.none)
                    ForEach(cameras) { Text("\($0.name) (\($0.index))").tag(Int?.some($0.index)) }
                }
                Button("Ver", action: onSnapshot).disabled(cameraIndex == nil)
            }
            if let snapshot, let image = NSImage(data: snapshot) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200).clipShape(.rect(cornerRadius: 10))
            }
            let others = cameras.filter { $0.index != cameraIndex }
            if !others.isEmpty {
                LabeledContent("Otras cámaras en vivo") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(others) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { extraCameras.contains(c.index) },
                                set: { on in extraCameras = on ? extraCameras + [c.index] : extraCameras.filter { $0 != c.index } }))
                        }
                    }
                }
                .help("Se ven junto a la principal en «En vivo» y la IA también mira por ellas (por ejemplo una vista desde arriba).")
            }
        } header: {
            Text("Brazos y cámara")
        } footer: {
            Text("Las calibraciones son las que hiciste con lerobot-calibrate. Si no aparece ninguna, calibra primero en la terminal (ver la guía).")
                .foregroundStyle(Theme.muted)
        }
    }
}
