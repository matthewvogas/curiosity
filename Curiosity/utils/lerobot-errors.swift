import Foundation

/// Los errores de LeRobot, dichos de forma que se entienda qué hacer.
enum LeRobotErrors {
    static func friendly(_ raw: String) -> String {
        let t = raw.lowercased()
        // Los avisos del puente que ya dicen qué hacer se muestran tal cual.
        if raw.hasPrefix("This model") { return raw }
        // Un problema leyendo la configuración no es la cámara: se muestra tal cual.
        if t.contains("failed when parsing") || t.contains("didn't accept the settings") { return "LeRobot didn't accept the settings: \(raw)" }
        if t.contains("camera") || t.contains("opencv") {
            return "The camera didn't respond. Check Curiosity's camera permission and make sure no other app is using it. (\(raw))"
        }
        if t.contains("busy") || t.contains("resource temporarily") { return "The robot's port is being used by another app." }
        if t.contains("no such file") || t.contains("could not connect") || t.contains("missing motor") {
            return "An arm isn't responding. Check the USB cable and that its power supply is on."
        }
        if t.contains("calibrat") { return "The calibration doesn't match the motors. Calibrate again in the terminal." }
        if t.contains("fileexists") || t.contains("file exists") { return "A folder with that name already exists. Try again." }
        return "LeRobot stopped: \(raw)"
    }
}
