import Foundation

/// Conversión entre las unidades del motor (SI: radianes, metros) y las que ve la persona o la IA
/// (grados para giros, centímetros para desplazamientos y posiciones).
enum Units {
    static func toDisplay(_ value: Double, jointType: String) -> Double {
        jointType == "prismatic" ? value * 100 : value * 180 / .pi
    }

    static func fromDisplay(_ value: Double, jointType: String) -> Double {
        jointType == "prismatic" ? value / 100 : value * .pi / 180
    }

    static func symbol(jointType: String) -> String {
        jointType == "prismatic" ? "cm" : "°"
    }

    static func format(_ value: Double, jointType: String) -> String {
        let v = toDisplay(value, jointType: jointType)
        return jointType == "prismatic" ? String(format: "%.1f cm", v) : String(format: "%.0f°", v)
    }

    static func centimeters(_ meters: [Double]) -> [Double] { meters.map { ($0 * 1000).rounded() / 10 } }
    static func meters(_ centimeters: [Double]) -> [Double] { centimeters.map { $0 / 100 } }

    /// Una medida para leer: en cm, o en m desde 1 m («3 cm», «1.2 m»).
    static func length(_ meters: Double) -> String {
        meters >= 1 ? String(format: "%.1f m", meters) : String(format: meters < 0.1 ? "%.1f cm" : "%.0f cm", meters * 100)
    }

    /// Un peso para leer: en g, o en kg desde 1 kg.
    static func weight(_ kg: Double) -> String {
        kg >= 1 ? String(format: kg >= 10 ? "%.0f kg" : "%.1f kg", kg) : "\(Int((kg * 1000).rounded())) g"
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Una duración larga para leer: «3 h 17 min», «12 min».
    static func duration(_ seconds: Double) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// «1:02:03» o «02:03» (como los escribe tqdm) → segundos.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == text.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
