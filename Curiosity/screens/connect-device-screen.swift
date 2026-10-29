import SwiftUI

/// Conectar robot externo: un SO-101 son dos brazos. Se elige cuál es el follower (el que trabaja) y
/// cuál el leader (el que mueves con la mano para guiarlo).
struct ConnectDeviceScreen: View {
    @Environment(UseDevices.self) private var devices
    @Environment(\.dismiss) private var dismiss
    @State private var follower: String?
    @State private var leader: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Connect a robot").font(.title2.weight(.semibold))
                Text("Plug in both arms and turn on their power.")
                    .font(.callout).foregroundStyle(Theme.muted)
            }

            if devices.available.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    ProgressView().controlSize(.small)
                    Text("Looking for plugged-in arms…").font(.callout).foregroundStyle(Theme.muted)
                }
            } else {
                Form {
                    Picker("Follower (the one that works)", selection: $follower) {
                        Text("Choose…").tag(String?.none)
                        ForEach(devices.available, id: \.self) { Text(short($0)).tag(String?.some($0)) }
                    }
                    Picker("Leader (the one you move)", selection: $leader) {
                        Text("No leader").tag(String?.none)
                        ForEach(devices.available.filter { $0 != follower }, id: \.self) { Text(short($0)).tag(String?.some($0)) }
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .frame(height: 120)
                Text("Unplug one arm to see which port is which.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            OptionCard(icon: .robot, title: "Other robots", detail: "Koch, LeKiwi, OpenArm and more.",
                       badge: "Coming soon", enabled: false) {}

            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    if let follower { devices.add(follower: follower, leader: leader) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(follower == nil)
            }
        }
        .padding(Theme.Space.xxl)
        .frame(width: 500)
        .onChange(of: devices.available) {
            if follower == nil, let first = devices.available.first { follower = first }
            if leader == nil { leader = devices.available.first { $0 != follower } }
        }
        .onAppear {
            follower = devices.available.first
            leader = devices.available.first { $0 != follower }
        }
    }

    private func short(_ port: String) -> String { port.replacingOccurrences(of: "/dev/cu.", with: "") }
}
