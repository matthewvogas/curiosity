import Foundation

/// Nombres de carpeta a partir de texto libre: «Pon el cubo rojo en el vaso» → «pon_el_cubo_rojo_en_el_vaso».
enum Naming {
    static func slug(_ text: String, max: Int = 40) -> String {
        let plain = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "es")).lowercased()
        let parts = plain.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let slug = String(parts.joined(separator: "_").prefix(max)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "tarea" : slug
    }

    /// `base`, o `base_2`, `base_3`… si ya existe.
    static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var i = 2
        while taken.contains("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }
}
