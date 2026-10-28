import Foundation
import Observation

/// Datasets: los de esta Mac (grabados en la app y bajados del Hub) y la búsqueda en Hugging Face.
@Observable
final class UseDatasets {
    private let lerobot: UseLeRobot
    private let settings: UseSettings

    private(set) var local: [DatasetInfo] = []
    private(set) var hub: [HubDataset] = []
    var query = "so101"
    private(set) var searching = false
    private(set) var loading = false
    private(set) var message: String?

    init(lerobot: UseLeRobot, settings: UseSettings) {
        self.lerobot = lerobot
        self.settings = settings
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let raw = try await lerobot.datasets(roots: [AppPaths.datasets.path, AppPaths.hubCache.path])
            local = raw.map { d in
                DatasetInfo(name: d["name"] as? String ?? "", root: d["root"] as? String ?? "", source: d["source"] as? String ?? "local",
                            episodes: (d["episodes"] as? NSNumber)?.intValue ?? 0, frames: (d["frames"] as? NSNumber)?.intValue ?? 0,
                            fps: (d["fps"] as? NSNumber)?.doubleValue, tasks: d["tasks"] as? [String] ?? [],
                            bytes: (d["bytes"] as? NSNumber)?.intValue ?? 0, cameras: d["cameras"] as? [String] ?? [])
            }
            .sorted { $0.name < $1.name }
        } catch {
            message = error.localizedDescription
        }
    }

    func search() async {
        searching = true
        defer { searching = false }
        do {
            hub = try await HubQueries.searchDatasets(query, token: settings.hubToken)
            message = hub.isEmpty ? "Nothing for “\(query)” on the Hub." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    func delete(_ d: DatasetInfo) async {
        do {
            _ = try await lerobot.request("delete_dataset", ["root": d.root])
            await load()
        } catch {
            message = error.localizedDescription
        }
    }
}
