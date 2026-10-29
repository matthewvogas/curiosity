import Foundation

/// Las unidades de LeRobot por articulación: «deg» (grados), «0-100» o «±100», según el motor. Lo que no va en
/// grados se reparte sobre el rango de esa articulación en el modelo 3D (su URDF).
enum JointUnits {
    static func toModel(_ value: Double, unit: String, lower: Double?, upper: Double?) -> Double? {
        if unit == "deg" { return value * .pi / 180 }
        guard let lower, let upper else { return nil }
        let fraction = unit == "0-100" ? value / 100 : (value + 100) / 200
        return lower + fraction * (upper - lower)
    }

    static func fromModel(_ q: Double, unit: String, lower: Double?, upper: Double?) -> Double? {
        if unit == "deg" { return q * 180 / .pi }
        guard let lower, let upper, upper > lower else { return nil }
        let fraction = (q - lower) / (upper - lower)
        return unit == "0-100" ? fraction * 100 : fraction * 200 - 100
    }

    /// Un valor con su unidad, para mostrar.
    static func format(_ value: Double, _ unit: String?) -> String {
        unit == "deg" ? "\(Int(value.rounded()))°" : "\(Int(value.rounded()))"
    }
}
