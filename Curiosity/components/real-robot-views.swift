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
    @Binding var extraCameras: [String]
    let snapshot: Data?
    let onSnapshot: () -> Void

    var body: some View {
        Section {
            Picker("Follower calibration", selection: $followerID) {
                Text("Choose…").tag(String?.none)
                ForEach(followers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Leader port", selection: $leaderPort) {
                Text("No leader").tag(String?.none)
                ForEach(otherPorts, id: \.self) { Text($0.replacingOccurrences(of: "/dev/cu.", with: "")).tag(String?.some($0)) }
            }
            Picker("Leader calibration", selection: $leaderID) {
                Text("Choose…").tag(String?.none)
                ForEach(leaders, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .disabled(leaderPort == nil)
            HStack {
                Picker("Camera", selection: $cameraIndex) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(cameras) { Text("\($0.name) (\($0.index))").tag(Int?.some($0.index)) }
                }
                Button("Preview", action: onSnapshot).disabled(cameraIndex == nil)
            }
            if let snapshot, let image = NSImage(data: snapshot) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200).clipShape(.rect(cornerRadius: 10))
            }
            let others = cameras.filter { $0.index != cameraIndex }
            if !others.isEmpty {
                LabeledContent("Other cameras in Live") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(others) { c in
                            Toggle(c.name, isOn: Binding(
                                get: { extraCameras.contains(c.name) },
                                set: { on in extraCameras = on ? extraCameras + [c.name] : extraCameras.filter { $0 != c.name } }))
                        }
                    }
                }
                .help("Shown next to the main camera in Live, and the AI looks through them too (for example, a top-down view).")
            }
        } header: {
            Text("Arms and camera")
        } footer: {
            Text("These are the calibrations you made with lerobot-calibrate. If none show up, calibrate in the terminal first (see the guide).")
                .foregroundStyle(Theme.muted)
        }
    }
}
