/**
 * Compatibilidad con los archivos que escribía la versión de macOS (Swift Codable), para que robots, chats,
 * tareas y dispositivos se sigan leyendo igual:
 *  · Date  → número de segundos desde el 1 de enero de 2001 (referencia de Apple).
 *  · UUID  → texto en mayúsculas.
 *  · Data  → base64.
 *  · Optional vacío → la clave no está.
 * En la app los tipos usan estos mismos valores crudos (SwiftDate, UUID como string), y se convierten
 * solo para mostrarlos.
 */

/** Segundos desde 2001-01-01T00:00:00Z. */
export type SwiftDate = number;

const APPLE_EPOCH_MS = Date.UTC(2001, 0, 1);

export const swiftDate = {
  now: (): SwiftDate => (Date.now() - APPLE_EPOCH_MS) / 1000,
  toDate: (d: SwiftDate): Date => new Date(APPLE_EPOCH_MS + d * 1000),
  fromDate: (d: Date): SwiftDate => (d.getTime() - APPLE_EPOCH_MS) / 1000,
  /** Date.distantPast de Swift. */
  distantPast: -63114076800,
};

export function uuid(): string {
  return crypto.randomUUID().toUpperCase();
}

/** Base64 (con o sin prefijo data:) → bytes. */
export function base64ToBytes(b64: string): Uint8Array {
  const clean = b64.includes(",") ? b64.slice(b64.indexOf(",") + 1) : b64;
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Texto ↔ base64 en UTF-8 (p. ej. Conversation.history, que en Swift es Data con JSON adentro). */
export const utf8Base64 = {
  encode: (text: string) => bytesToBase64(new TextEncoder().encode(text)),
  decode: (b64: string) => new TextDecoder().decode(base64ToBytes(b64)),
};

export const jpegDataURL = (b64: string) => (b64.startsWith("data:") ? b64 : `data:image/jpeg;base64,${b64}`);
