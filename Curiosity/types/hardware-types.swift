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
        case .dynamixel2: "Dynamixel (protocolo 2.0)"
        case .dynamixel1: "Dynamixel (protocolo 1.0)"
        }
    }

    var example: String {
        switch self {
        case .feetech: "SO-100, SO-101, LeKiwi"
        case .dynamixel2: "Koch, ALOHA, X-series"
        case .dynamixel1: "AX-12, MX-28"
        }
    }

    var defaultBaud: Int {
        switch self {
        case .feetech: 1_000_000
        case .dynamixel2: 1_000_000
        case .dynamixel1: 1_000_000
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
        default: "Modelo \(model)"
        }
    }

}

/// Con qué puerto, tipo de motores y velocidad se habla con el robot físico de un modelo.
struct HardwareProfile: Codable, Equatable {
    var port: String?
    var bus: BusProtocol = .feetech
    var baud = 1_000_000
}
