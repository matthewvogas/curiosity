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

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
