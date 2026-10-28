import Foundation

/// Familias de servos en bus serie. Cubre la mayoría de los brazos abiertos (SO-100/101, Koch,
/// LeKiwi, ALOHA, Trossen, Robotis).
nonisolated enum BusProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case feetech       // STS/SMS (STS3215…): SO-100, SO-101, LeKiwi
    case dynamixel2    // Dynamixel protocolo 2.0 (X-series): Koch, ALOHA, Robotis
    case dynamixel1    // Dynamixel protocolo 1.0 (AX, MX)

    var id: String { rawValue }

    var name: String {
        switch self {
        case .feetech: "Feetech STS / SMS"
        case .dynamixel2: "Dynamixel (protocol 2.0)"
        case .dynamixel1: "Dynamixel (protocol 1.0)"
        }
    }

    /// Direcciones de los registros que se usan: (dirección, bytes).
    struct Registers {
        let model: (UInt16, Int)
        let present: (UInt16, Int)
    }

    var registers: Registers {
        switch self {
        case .feetech: Registers(model: (3, 2), present: (56, 2))
        case .dynamixel2: Registers(model: (0, 2), present: (132, 4))
        case .dynamixel1: Registers(model: (0, 2), present: (36, 2))
        }
    }
}

/// Un motor que respondió en el bus.
nonisolated struct FoundMotor: Identifiable, Equatable, Codable, Sendable {
    var id: Int
    var model: Int
    var position: Int?

    var modelName: String {
        switch model {
        case 777: "STS3215"
        case 2825: "STS3250"
        case 1284: "SCS0009"
        case 12: "AX-12"
        case 29: "MX-28"
        case 1060: "XL430-W250"
        case 1200: "XL330-M288"
        case 1190: "XL330-M077"
        case 1020: "XM430-W350"
        case 1030: "XM430-W210"
        case 1120: "XM540-W270"
        case 1090: "XH430-V350"
        default: "Model \(model)"
        }
    }

}

/// Un robot físico conectado por USB (un adaptador serie). Su id es el puerto.
struct Device: Identifiable, Codable, Equatable {
    var id: String              // /dev/cu.usbmodem… (el follower)
    var name: String
    var bus: BusProtocol = .feetech
    var baud = 1_000_000
    var found: [FoundMotor] = []
    var probedAt: Date?
    /// Nombre de la calibración del follower en LeRobot (--robot.id).
    var followerID: String?
    /// El leader (el brazo que mueves con la mano): su puerto y su calibración (--teleop.id).
    var leaderPort: String?
    var leaderID: String?
    /// La cámara para grabar y para los modelos (índice de OpenCV) y su nombre, para reconocerla.
    var cameraIndex: Int?
    var cameraName: String?
    /// Otras cámaras (por nombre: los números cambian al enchufar otra) que se ven en vivo y que la IA puede
    /// mirar, p. ej. una vista desde arriba.
    var extraCameraNames: [String]?

    var extraNames: [String] { extraCameraNames ?? [] }

    var canTeleoperate: Bool { followerID != nil && leaderPort != nil && leaderID != nil }
    var canRecord: Bool { canTeleoperate && cameraIndex != nil }
    var canRunPolicy: Bool { followerID != nil && cameraIndex != nil }

    /// Lo que se ve en la lista cuando nadie le puso nombre.

    /// Qué parece ser, por los motores que respondieron.
    var guess: String? {
        guard !found.isEmpty else { return nil }
        let models = Set(found.map(\.modelName))
        if models == ["STS3215"], found.count == 6 { return "SO-101" }
        return "\(found.count) motors"
    }
}
