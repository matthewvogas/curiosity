import Foundation
import Darwin

/// Puerto serie (USB) con POSIX: abrir en exclusiva, configurar la velocidad, escribir y leer con
/// tiempo límite. Lo usa solo `ServoBus`, fuera del hilo principal.
nonisolated final class SerialPort: @unchecked Sendable {
    struct SerialError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let path: String
    private var fd: Int32 = -1

    init(path: String) { self.path = path }

    /// Los puertos USB serie de la Mac (los de «llamada», /dev/cu.*).
    static func available() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .sorted().map { "/dev/\($0)" }
    }

    func open(baud: Int) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let busy = errno == EBUSY
            throw SerialError(message: busy ? "The port is being used by another app (LeRobot or the panel?)."
                                            : "Couldn't open \(path): \(String(cString: strerror(errno))).")
        }
        // Exclusivo: que ningún otro programa mande órdenes al mismo tiempo.
        if ioctl(fd, TIOCEXCL) == -1 {
            close()
            throw SerialError(message: "The port is being used by another app.")
        }
        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(CRTSCTS)
        tcsetattr(fd, TCSANOW, &options)
        // Velocidades no estándar (1 000 000) en macOS: IOSSIOSPEED.
        var speed = speed_t(baud)
        let IOSSIOSPEED: UInt = 0x8008_5402
        if ioctl(fd, IOSSIOSPEED, &speed) == -1 {
            close()
            throw SerialError(message: "Couldn't set the port to \(baud) baud.")
        }
        tcflush(fd, TCIOFLUSH)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    var isOpen: Bool { fd >= 0 }

    func flushInput() { if fd >= 0 { tcflush(fd, TCIFLUSH) } }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN { usleep(200); continue }
                throw SerialError(message: "Lost the connection to the port.")
            }
            offset += n
        }
    }

    /// Lee exactamente `count` bytes o lo que llegue antes de `timeout` segundos.
    func read(_ count: Int, timeout: Double) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        while out.count < count {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, remaining * 1000))) > 0 else { break }
            let n = Darwin.read(fd, &buffer, min(buffer.count, count - out.count))
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }
}
