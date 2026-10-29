//! Puertos USB serie y buses de servos (Feetech o Dynamixel). Solo lee (ping y posición): nunca manda
//! órdenes de movimiento.
//!
//! Protocolo 1 (Feetech STS y Dynamixel 1.0):  FF FF ID LEN INSTR PARAMS… CHECKSUM
//! Protocolo 2 (Dynamixel 2.0):                FF FF FD 00 ID LEN_L LEN_H INSTR PARAMS… CRC_L CRC_H

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use serde::Serialize;
use serialport::{SerialPort, SerialPortType};
use tauri::{AppHandle, Emitter};

/// Puertos USB serie conectados ahora (no abre ninguno).
/// macOS: los de «llamada» (/dev/cu.usb…). Windows: COM3, COM4… de adaptadores USB.
#[tauri::command]
pub fn serial_ports() -> Vec<String> {
    let mut ports: Vec<String> = serialport::available_ports()
        .unwrap_or_default()
        .into_iter()
        .filter(|p| matches!(p.port_type, SerialPortType::UsbPort(_)) || p.port_name.contains("usb"))
        .map(|p| p.port_name)
        .filter(|name| !cfg!(target_os = "macos") || name.starts_with("/dev/cu."))
        .collect();
    ports.sort();
    ports.dedup();
    ports
}

#[derive(Clone, Copy, PartialEq)]
enum Bus {
    Feetech,
    Dynamixel2,
    Dynamixel1,
}

impl Bus {
    fn parse(s: &str) -> Bus {
        match s {
            "dynamixel2" => Bus::Dynamixel2,
            "dynamixel1" => Bus::Dynamixel1,
            _ => Bus::Feetech,
        }
    }
    /// (dirección, bytes) del modelo y de la posición actual.
    fn registers(self) -> ((u16, usize), (u16, usize)) {
        match self {
            Bus::Feetech => ((3, 2), (56, 2)),
            Bus::Dynamixel2 => ((0, 2), (132, 4)),
            Bus::Dynamixel1 => ((0, 2), (36, 2)),
        }
    }
}

#[derive(Serialize)]
pub struct FoundMotor {
    id: u8,
    model: i64,
    position: Option<i64>,
}

struct Servo {
    port: Box<dyn SerialPort>,
    bus: Bus,
}

const PING: u8 = 0x01;
const READ: u8 = 0x02;

impl Servo {
    fn read_bytes(&mut self, count: usize, timeout: Duration) -> Vec<u8> {
        let deadline = Instant::now() + timeout;
        let mut out = Vec::with_capacity(count);
        let mut buf = [0u8; 256];
        while out.len() < count {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            let _ = self.port.set_timeout(left.max(Duration::from_millis(1)));
            match self.port.read(&mut buf[..(count - out.len()).min(256)]) {
                Ok(0) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(_) => break,
            }
        }
        out
    }

    fn transact(&mut self, id: u8, instruction: u8, params: &[u8], timeout: Duration) -> Option<Vec<u8>> {
        let _ = self.port.clear(serialport::ClearBuffer::Input);
        let packet = if self.bus == Bus::Dynamixel2 { packet2(id, instruction, params) } else { packet1(id, instruction, params) };
        self.port.write_all(&packet).ok()?;
        if self.bus == Bus::Dynamixel2 { self.receive2(id, timeout) } else { self.receive1(id, timeout) }
    }

    fn receive1(&mut self, id: u8, timeout: Duration) -> Option<Vec<u8>> {
        let mut head = self.read_bytes(4, timeout);
        // Sincroniza con FF FF (puede haber ruido antes).
        while head.len() == 4 && !(head[0] == 0xFF && head[1] == 0xFF) {
            head.remove(0);
            head.extend(self.read_bytes(1, timeout));
        }
        if head.len() != 4 || head[2] != id {
            return None;
        }
        let length = head[3] as usize;
        let rest = self.read_bytes(length, timeout);
        if rest.len() != length || length < 2 {
            return None;
        }
        let sum: u32 = head[2] as u32 + head[3] as u32 + rest[..length - 1].iter().map(|&b| b as u32).sum::<u32>();
        if (!sum & 0xFF) as u8 != rest[length - 1] {
            return None;
        }
        Some(rest[1..length - 1].to_vec()) // sin el byte de error ni el checksum
    }

    fn receive2(&mut self, id: u8, timeout: Duration) -> Option<Vec<u8>> {
        let mut head = self.read_bytes(7, timeout);
        while head.len() == 7 && !(head[0] == 0xFF && head[1] == 0xFF && head[2] == 0xFD && head[3] == 0x00) {
            head.remove(0);
            head.extend(self.read_bytes(1, timeout));
        }
        if head.len() != 7 || head[4] != id {
            return None;
        }
        let length = head[5] as usize | (head[6] as usize) << 8;
        let rest = self.read_bytes(length, timeout);
        if rest.len() != length || length < 4 {
            return None;
        }
        let crc = rest[length - 2] as u16 | (rest[length - 1] as u16) << 8;
        let mut all = head.clone();
        all.extend_from_slice(&rest[..length - 2]);
        if crc16(&all) != crc || rest[0] != 0x55 {
            return None;
        }
        Some(unstuff(&rest[2..length - 2])) // sin instrucción (0x55), error ni CRC
    }

    fn read_register(&mut self, id: u8, (address, size): (u16, usize)) -> Option<i64> {
        let params: Vec<u8> = if self.bus == Bus::Dynamixel2 {
            vec![(address & 0xFF) as u8, (address >> 8) as u8, (size & 0xFF) as u8, (size >> 8) as u8]
        } else {
            vec![(address & 0xFF) as u8, size as u8]
        };
        let data = self.transact(id, READ, &params, Duration::from_millis(40))?;
        if data.len() < size {
            return None;
        }
        let mut value: i64 = 0;
        for (i, b) in data.iter().take(size).enumerate() {
            value |= (*b as i64) << (8 * i); // los tres protocolos son little-endian
        }
        Some(match (self.bus, size) {
            (Bus::Feetech, 2) if value & 0x8000 != 0 => -(value & 0x7FFF), // signo en el bit 15
            (Bus::Dynamixel2, 4) => value as i32 as i64,
            _ => value,
        })
    }

    fn ping(&mut self, id: u8) -> Option<i64> {
        let reply = self.transact(id, PING, &[], Duration::from_millis(12))?;
        if self.bus == Bus::Dynamixel2 && reply.len() >= 2 {
            return Some(reply[0] as i64 | (reply[1] as i64) << 8);
        }
        Some(self.read_register(id, self.bus.registers().0).unwrap_or(0))
    }
}

fn packet1(id: u8, instruction: u8, params: &[u8]) -> Vec<u8> {
    let mut body = vec![id, params.len() as u8 + 2, instruction];
    body.extend_from_slice(params);
    let sum: u32 = body.iter().map(|&b| b as u32).sum();
    let mut packet = vec![0xFF, 0xFF];
    packet.extend(body);
    packet.push((!sum & 0xFF) as u8);
    packet
}

fn packet2(id: u8, instruction: u8, params: &[u8]) -> Vec<u8> {
    let mut raw = vec![instruction];
    raw.extend_from_slice(params);
    let stuffed = stuff(&raw);
    let length = stuffed.len() + 2;
    let mut packet = vec![0xFF, 0xFF, 0xFD, 0x00, id, (length & 0xFF) as u8, (length >> 8) as u8];
    packet.extend(stuffed);
    let crc = crc16(&packet);
    packet.push((crc & 0xFF) as u8);
    packet.push((crc >> 8) as u8);
    packet
}

/// Dynamixel 2.0: después de FF FF FD se agrega otro FD para que no se confunda con un encabezado.
fn stuff(bytes: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = vec![];
    for &b in bytes {
        out.push(b);
        let n = out.len();
        if n >= 3 && out[n - 3] == 0xFF && out[n - 2] == 0xFF && b == 0xFD {
            out.push(0xFD);
        }
    }
    out
}

fn unstuff(bytes: &[u8]) -> Vec<u8> {
    let mut out = vec![];
    let mut i = 0;
    while i < bytes.len() {
        out.push(bytes[i]);
        if i >= 2 && bytes[i - 2] == 0xFF && bytes[i - 1] == 0xFF && bytes[i] == 0xFD && i + 1 < bytes.len() && bytes[i + 1] == 0xFD {
            i += 1;
        }
        i += 1;
    }
    out
}

/// CRC-16 de Dynamixel (polinomio 0x8005, sin reflejar, inicio 0).
fn crc16(bytes: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for &b in bytes {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x8005 } else { crc << 1 };
        }
    }
    crc
}

/// Abre el puerto, busca motores en los IDs 0–253 y lo cierra. Avisa el avance con `servo://progress`.
#[tauri::command]
pub async fn servo_scan(app: AppHandle, path: String, bus: String, baud: u32) -> Result<Vec<FoundMotor>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let port = serialport::new(&path, baud).timeout(Duration::from_millis(20)).open().map_err(|e| match e.kind() {
            serialport::ErrorKind::NoDevice => "The port is being used by another app (LeRobot or the panel?).".to_string(),
            _ => format!("Couldn't open {path}: {e}."),
        })?; // en macOS y Linux serialport lo abre en exclusiva: nadie más manda órdenes a la vez
        let mut servo = Servo { port, bus: Bus::parse(&bus) };
        let mut found = vec![];
        for id in 0u8..=253 {
            if let Some(model) = servo.ping(id) {
                let position = servo.read_register(id, servo.bus.registers().1);
                found.push(FoundMotor { id, model, position });
            }
            let _ = app.emit("servo://progress", (id as f64 + 1.0) / 254.0);
        }
        Ok(found)
    })
    .await
    .map_err(|e| e.to_string())?
}
