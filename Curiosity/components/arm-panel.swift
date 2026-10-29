import SwiftUI

/// El brazo que se mueve solo: qué cámaras están calibradas y la calibración guiada (la pinza va a cada punto
/// con «Move» y la persona hace clic donde ve su punta). Solo dibuja: todo por props.
struct ArmPanel: View {
    struct CameraRow: Identifiable {
        let name: String
        let frame: Data?
        let fit: CameraFit?
        var id: String { name }
    }

    let cameras: [CameraRow]
    let calibrating: String?
    let marked: [[Double]]           // píxeles (0…1) ya marcados
    let pointCount: Int
    let fit: CameraFit?              // el ajuste de lo marcado (desde 6 puntos)
    let busy: String?
    let error: String?
    let onStart: (String) -> Void
    let onMove: (Int) -> Void
    let onMark: (Double, Double) -> Void
    let onUndo: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arm").font(.headline)
                    Text("The AI points at things in a camera picture and the arm does the whole move on its own, with its kinematics and the limits of its calibration. For that the camera has to know where it is relative to the robot: calibrate it once.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if let calibrating, let cam = cameras.first(where: { $0.name == calibrating }) {
                    wizard(cam)
                } else {
                    ForEach(cameras) { cam in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.name)
                                if let fit = cam.fit {
                                    Label("Calibrated · error \(String(format: "%.1f", fit.errorPx)) px", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(fit.errorPx < 8 ? Theme.green : Theme.yellow)
                                } else {
                                    Text("Not calibrated").font(.caption).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            Button(cam.fit == nil ? "Calibrate" : "Redo") { onStart(cam.name) }
                                .buttonStyle(.glassProminent)
                                .disabled(busy != nil)
                        }
                    }
                }
                if let error { Text(error).font(.caption).foregroundStyle(Theme.red) }
            }
            .font(.callout)
            .padding(Theme.Space.l)
        }
        .scrollIndicators(.never)
    }

    private func wizard(_ cam: CameraRow) -> some View {
        let next = marked.count
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Calibrating \(cam.name)").font(.headline)
            Text(next < pointCount
                 ? "Point \(next + 1) of \(pointCount): press Move (the arm goes there slowly with the gripper closed), then click the tip of the gripper in the picture."
                 : "All points marked. Save if the error is low.")
                .font(.caption).foregroundStyle(Theme.muted)
            ZStack {
                if let frame = cam.frame, let image = NSImage(data: frame) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { g in
                                ZStack(alignment: .topLeading) {
                                    Color.clear.contentShape(Rectangle())
                                        .onTapGesture(coordinateSpace: .local) { p in
                                            guard busy == nil, next < pointCount else { return }
                                            onMark(p.x / g.size.width, p.y / g.size.height)
                                        }
                                    ForEach(Array(marked.enumerated()), id: \.offset) { i, m in
                                        Circle().stroke(Theme.green, lineWidth: 2).frame(width: 12, height: 12)
                                            .overlay(Text("\(i + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green).offset(x: 11, y: -9))
                                            .position(x: m[0] * g.size.width, y: m[1] * g.size.height)
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                } else {
                    ProgressView().frame(height: 200)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.Radius.row))
            HStack {
                Button("Move to point \(min(next + 1, pointCount))", systemImage: "arrow.up.and.down.and.arrow.left.and.right") { onMove(next) }
                    .buttonStyle(.glassProminent)
                    .disabled(busy != nil || next >= pointCount)
                if let busy { ProgressView().controlSize(.small); Text(busy).font(.caption).foregroundStyle(Theme.muted) }
            }
            HStack {
                Text("\(marked.count) of \(pointCount) points").font(.caption).foregroundStyle(Theme.muted)
                if let fit {
                    Text("· error \(String(format: "%.1f", fit.errorPx)) px").font(.caption)
                        .foregroundStyle(fit.errorPx < 8 ? Theme.green : Theme.yellow)
                }
                Spacer()
                Button("Undo", action: onUndo).buttonStyle(.link).disabled(marked.isEmpty || busy != nil)
            }
            if let fit, fit.errorPx >= 8 {
                Text("High error: a click may be off, or the 3D model doesn't match the real arm. Undo the odd point or redo.")
                    .font(.caption).foregroundStyle(Theme.yellow)
            }
            HStack {
                Button("Cancel", action: onCancel).disabled(busy != nil)
                Spacer()
                Button("Save", action: onSave).buttonStyle(.glassProminent).disabled(fit == nil || busy != nil)
            }
        }
    }
}
