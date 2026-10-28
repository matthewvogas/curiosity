import Foundation

/// Los errores de LeRobot, dichos de forma que se entienda qué hacer.
enum LeRobotErrors {
    static func friendly(_ raw: String) -> String {
        let t = raw.lowercased()
        if t.contains("camera") || t.contains("opencv") {
            return "La cámara no respondió. Revisa el permiso de cámara de Curiosity y que ningún otro programa la use."
        }
        if t.contains("busy") || t.contains("resource temporarily") { return "El puerto del robot está ocupado por otro programa." }
        if t.contains("no such file") || t.contains("could not connect") || t.contains("missing motor") {
            return "Un brazo no responde. Revisa el cable USB y que su fuente esté encendida."
        }
        if t.contains("calibrat") { return "La calibración no coincide con los motores. Calibra de nuevo en la terminal." }
        if t.contains("fileexists") || t.contains("file exists") { return "Ya había una carpeta con ese nombre. Intenta de nuevo." }
        return "LeRobot se detuvo: \(raw)"
    }
}
