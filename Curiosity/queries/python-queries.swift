import Foundation

/// Dónde está instalado LeRobot en esta Mac. Busca en los lugares de costumbre (un .venv dentro de una carpeta
/// «lerobot», o un entorno de conda llamado «lerobot») y acepta el Python que tiene `lerobot-record` al lado.
enum PythonQueries {
    private static let skipped: Set = ["Library", "Applications", "Pictures", "Music", "Movies", "node_modules",
                                              "Desktop", "Documents", "Downloads"]  // estas tres piden permiso a la persona

    static func findLeRobot() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var envs: [URL] = []
        // Una carpeta «lerobot» hasta tres niveles dentro de la carpeta personal (p. ej. ~/Code/robots/lerobot), con su .venv o venv.
        var roots = [home]
        for depth in 0..<3 {
            var next: [URL] = []
            for dir in roots {
                let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for c in children where (try? c.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if c.lastPathComponent.lowercased() == "lerobot" {
                        envs += [c.appendingPathComponent(".venv"), c.appendingPathComponent("venv")]
                    }
                    if depth < 2, !Self.skipped.contains(c.lastPathComponent) { next.append(c) }
                }
            }
            roots = next
        }
        // Entornos de conda / miniforge.
        for base in ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "opt/miniconda3", "opt/anaconda3"] {
            envs.append(home.appendingPathComponent(base).appendingPathComponent("envs/lerobot"))
        }
        envs.append(URL(fileURLWithPath: "/opt/homebrew/Caskroom/miniconda/base/envs/lerobot"))

        return envs.lazy
            .filter { fm.isExecutableFile(atPath: $0.appendingPathComponent("bin/lerobot-record").path) }
            .map { $0.appendingPathComponent("bin/python").path }
            .first { fm.isExecutableFile(atPath: $0) }
    }
}
