import SwiftUI

// Ajustes del robot real. Solo dibujan: datos y acciones llegan por props.

/// Cómo se arma el robot: su tipo en LeRobot, calibraciones, el leader, el modelo 3D y la cámara.
struct RobotSetupView: View {
    let robotKinds: [String]
    let teleopKinds: [String]
    let models: [(id: String, name: String)]
    @Binding var robotType: String?
    @Binding var teleopType: String?
    @Binding var modelID: String?
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
    let onRefreshCameras: () -> Void

    var body: some View {
        Section {
            Picker("Robot type", selection: $robotType) {
                Text("Choose…").tag(String?.none)
                ForEach(robotKinds, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Follower calibration", selection: $followerID) {
                Text("Choose…").tag(String?.none)
                ForEach(followers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Leader type", selection: $teleopType) {
                Text("Choose…").tag(String?.none)
                ForEach(teleopKinds, id: \.self) { Text($0).tag(String?.some($0)) }
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
            Picker("3D model", selection: $modelID) {
                Text("None").tag(String?.some(""))
                ForEach(models, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
            }
            HStack {
                Picker("Camera", selection: $cameraIndex) {
                    Text("Choose…").tag(Int?.none)
                    ForEach(cameras) { Text("\($0.name) (\($0.index))").tag(Int?.some($0.index)) }
                }
                Button("Preview", action: onSnapshot).disabled(cameraIndex == nil)
                Button(action: onRefreshCameras) { Image(systemName: "arrow.clockwise") }
                    .help("Search for cameras again")
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
                .help("Also shown in Live")
            }
        } header: {
            Text("Robot")
        } footer: {
            if followers.isEmpty { Text("No calibrations found. Run lerobot-calibrate.").foregroundStyle(Theme.muted) }
        }
    }
}

/// Ajuste rápido antes de probar un modelo: qué cámara es cada una de las que el modelo espera y qué calibración.
struct RunSetupView: View {
    let modelCameras: [String]
    let cameras: [CameraInfo]
    let followers: [String]
    @Binding var followerID: String?
    @Binding var slots: [Int?]
    let previews: [Int: Data]
    let onPreview: (Int) -> Void
    let onRefreshCameras: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(Array(modelCameras.enumerated()), id: \.offset) { slot, name in
                        HStack {
                            Picker("«\(name)»", selection: Binding(
                                get: { slots.indices.contains(slot) ? slots[slot] : nil },
                                set: { v in
                                    var s = slots + Array(repeating: nil, count: max(0, modelCameras.count - slots.count))
                                    s[slot] = v
                                    slots = s
                                })) {
                                Text("Choose…").tag(Int?.none)
                                ForEach(cameras) { Text($0.name).tag(Int?.some($0.index)) }
                            }
                            Button("Preview") { if let i = slots[safe: slot] ?? nil { onPreview(i) } }
                                .disabled((slots[safe: slot] ?? nil) == nil)
                        }
                        if let i = slots[safe: slot] ?? nil, let data = previews[i], let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 160).clipShape(.rect(cornerRadius: 10))
                        }
                    }
                } header: {
                    HStack {
                        Text(modelCameras.count == 1 ? "Camera" : "Cameras")
                        Spacer()
                        Button(action: onRefreshCameras) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Search for cameras again")
                    }
                } footer: {
                    if modelCameras.count > 1 {
                        Text("Place each camera where it was during training.").foregroundStyle(Theme.muted)
                    }
                }
                Section("Arm") {
                    Picker("Follower calibration", selection: $followerID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(followers, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done", action: onDone).keyboardShortcut(.defaultAction) }
                .padding(Theme.Space.l)
        }
        .frame(width: 520, height: 560)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
