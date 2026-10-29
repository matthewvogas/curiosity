import { Files, invoke, join, on } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { BusProtocol, Device, FoundMotor } from "@/types/hardware-types";

/**
 * Mis robots físicos (devices.json): nombre y la última prueba de cada puerto. Que estén enchufados ahora
 * lo dice `connectedPorts()`. Los buses de servos solo se leen: nunca se manda una orden de movimiento.
 */
export const DeviceQueries = {
  known: async () => (await Files.readJSON<Device[]>(join(AppPaths.root, "devices.json"))) ?? [],
  save: (devices: Device[]) => Files.writeJSON(join(AppPaths.root, "devices.json"), devices),

  /** Puertos USB serie conectados ahora (no abre ninguno): /dev/cu.usb… en macOS, COM3… en Windows. */
  connectedPorts: () => invoke<string[]>("serial_ports"),

  /** Abre el puerto, busca motores en los IDs 0–253 y lo cierra. `progress` recibe la fracción revisada. */
  async scan(port: string, bus: BusProtocol, baud: number, progress: (f: number) => void): Promise<FoundMotor[]> {
    const stop = await on<number>("servo://progress", progress);
    try {
      return await invoke<FoundMotor[]>("servo_scan", { path: port, bus, baud });
    } finally {
      stop();
    }
  },
};
