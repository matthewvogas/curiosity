import Foundation

/// Un bus de servos serie (Feetech o Dynamixel): arma y lee los paquetes de cada protocolo.
/// Solo lee (ping y posición): nunca manda órdenes de movimiento.
/// Corre fuera del hilo principal (es un actor) porque la lectura del puerto bloquea.
///
/// Protocolo 1 (Feetech STS y Dynamixel 1.0):  FF FF ID LEN INSTR PARAMS… CHECKSUM
/// Protocolo 2 (Dynamixel 2.0):                FF FF FD 00 ID LEN_L LEN_H INSTR PARAMS… CRC_L CRC_H
actor ServoBus {
    private let port: SerialPort
    let bus: BusProtocol
    let baud: Int

    private enum Instruction: UInt8 { case ping = 0x01, read = 0x02 }

    init(path: String, bus: BusProtocol, baud: Int) {
        port = SerialPort(path: path)
        self.bus = bus
        self.baud = baud
    }

    func open() throws { try port.open(baud: baud) }
    func close() { port.close() }

    // MARK: - Operaciones

    /// Busca motores en los IDs dados. `progress` recibe la fracción revisada.
    func scan(ids: ClosedRange<Int> = 0...253, progress: @Sendable (Double) -> Void) -> [FoundMotor] {
        var found: [FoundMotor] = []
        for id in ids {
            if let model = ping(id) {
                found.append(FoundMotor(id: id, model: model, position: readPosition(id)))
            }
            progress(Double(id - ids.lowerBound + 1) / Double(ids.count))
        }
        return found
    }

    /// Modelo del motor si responde; nil si no hay nadie en ese ID.
    func ping(_ id: Int) -> Int? {
        guard let reply = transact(id: id, .ping, [], timeout: 0.012) else { return nil }
        if bus == .dynamixel2, reply.count >= 2 { return Int(reply[0]) | Int(reply[1]) << 8 }
        return read(id, bus.registers.model) ?? 0
    }

    func readPosition(_ id: Int) -> Int? { read(id, bus.registers.present) }

    func readPositions(_ ids: [Int]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for id in ids { if let p = readPosition(id) { out[id] = p } }
        return out
    }

    // MARK: - Registros

    private func read(_ id: Int, _ register: (UInt16, Int)) -> Int? {
        let (address, size) = register
        let params: [UInt8] = bus == .dynamixel2
            ? [UInt8(address & 0xFF), UInt8(address >> 8), UInt8(size & 0xFF), UInt8(size >> 8)]
            : [UInt8(address & 0xFF), UInt8(size)]
        guard let data = transact(id: id, .read, params, timeout: 0.04), data.count >= size else { return nil }
        var value = 0
        for i in 0..<size { value |= Int(data[i]) << (8 * i) }   // los tres protocolos son little-endian
        switch (bus, size) {
        case (.feetech, 2): return value & 0x8000 != 0 ? -(value & 0x7FFF) : value   // signo en el bit 15
        case (.dynamixel2, 4): return Int(Int32(truncatingIfNeeded: value))
        default: return value
        }
    }

    // MARK: - Paquetes

    /// Manda una instrucción y devuelve los parámetros de la respuesta (nil si no respondió o vino mal).
    private func transact(id: Int, _ instruction: Instruction, _ params: [UInt8], timeout: Double) -> [UInt8]? {
        guard port.isOpen else { return nil }
        port.flushInput()
        let packet = bus == .dynamixel2 ? Self.packet2(id, instruction.rawValue, params) : Self.packet1(id, instruction.rawValue, params)
        do { try port.write(packet) } catch { return nil }
        return bus == .dynamixel2 ? receive2(id: id, timeout: timeout) : receive1(id: id, timeout: timeout)
    }

    static func packet1(_ id: Int, _ instruction: UInt8, _ params: [UInt8]) -> [UInt8] {
        let body: [UInt8] = [UInt8(id), UInt8(params.count + 2), instruction] + params
        let sum = body.reduce(0) { $0 + Int($1) }
        return [0xFF, 0xFF] + body + [UInt8(~sum & 0xFF)]
    }

    private func receive1(id: Int, timeout: Double) -> [UInt8]? {
        var head = port.read(4, timeout: timeout)
        // Sincroniza con FF FF (puede haber ruido antes).
        while head.count == 4, !(head[0] == 0xFF && head[1] == 0xFF) {
            head.removeFirst()
            head += port.read(1, timeout: timeout)
        }
        guard head.count == 4, Int(head[2]) == id else { return nil }
        let length = Int(head[3])
        let rest = port.read(length, timeout: timeout)
        guard rest.count == length, length >= 2 else { return nil }
        let sum = (Int(head[2]) + Int(head[3]) + rest.dropLast().reduce(0) { $0 + Int($1) })
        guard UInt8(~sum & 0xFF) == rest.last else { return nil }
        return Array(rest.dropFirst().dropLast())   // sin el byte de error ni el checksum
    }

    static func packet2(_ id: Int, _ instruction: UInt8, _ params: [UInt8]) -> [UInt8] {
        let stuffed = stuff([instruction] + params)
        let length = stuffed.count + 2
        var packet: [UInt8] = [0xFF, 0xFF, 0xFD, 0x00, UInt8(id), UInt8(length & 0xFF), UInt8(length >> 8)] + stuffed
        let crc = crc16(packet)
        packet += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        return packet
    }

    private func receive2(id: Int, timeout: Double) -> [UInt8]? {
        var head = port.read(7, timeout: timeout)
        while head.count == 7, !(head[0] == 0xFF && head[1] == 0xFF && head[2] == 0xFD && head[3] == 0x00) {
            head.removeFirst()
            head += port.read(1, timeout: timeout)
        }
        guard head.count == 7, Int(head[4]) == id else { return nil }
        let length = Int(head[5]) | Int(head[6]) << 8
        let rest = port.read(length, timeout: timeout)
        guard rest.count == length, length >= 4 else { return nil }
        let crc = Int(rest[length - 2]) | Int(rest[length - 1]) << 8
        guard Self.crc16(head + rest.dropLast(2)) == crc, rest[0] == 0x55 else { return nil }
        return Self.unstuff(Array(rest[2..<(length - 2)]))   // sin instrucción (0x55), error ni CRC
    }

    /// Dynamixel 2.0: después de FF FF FD se agrega otro FD para que no se confunda con un encabezado.
    static func stuff(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in bytes {
            out.append(b)
            if out.count >= 3, out[out.count - 3] == 0xFF, out[out.count - 2] == 0xFF, b == 0xFD { out.append(0xFD) }
        }
        return out
    }

    static func unstuff(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if i >= 2, bytes[i - 2] == 0xFF, bytes[i - 1] == 0xFF, bytes[i] == 0xFD, i + 1 < bytes.count, bytes[i + 1] == 0xFD { i += 1 }
            i += 1
        }
        return out
    }

    /// CRC-16 de Dynamixel (polinomio 0x8005, sin reflejar, inicio 0).
    static func crc16(_ bytes: [UInt8]) -> Int {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return Int(crc)
    }
}
