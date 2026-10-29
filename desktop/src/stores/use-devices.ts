import { makeAutoObservable, runInAction, toJS } from "mobx";
import { DeviceQueries } from "@/queries/device-queries";
import { Preferences } from "@/queries/preferences";
import { newDevice, type Device } from "@/types/hardware-types";
import { swiftDate } from "@/utils/codable";

export type Probe = { state: "idle" } | { state: "running"; progress: number } | { state: "failed"; message: string };

/**
 * Mis robots físicos (por ahora, el SO-101 por USB). Se agregan a mano desde «Conectar robot externo»;
 * la app solo mira qué puertos hay enchufados (sin abrirlos) y abre uno únicamente al probarlo.
 * Solo lee: nunca mueve el robot. Configurar y calibrar los motores se hace con LeRobot en la terminal.
 */
export class UseDevices {
  /** Los que agregué (estén o no enchufados ahora). */
  devices: Device[] = [];
  /** Puertos USB enchufados ahora (/dev/cu.usb… en macOS, COM3… en Windows). */
  connectedPorts: string[] = [];
  selectedID: string | null = Preferences.get<string | null>("devices.selected", null);
  probe: Probe = { state: "idle" };

  private watcher: ReturnType<typeof setInterval> | null = null;

  constructor() {
    makeAutoObservable<UseDevices, "watcher">(this, { watcher: false });
    void this.load();
    void this.refresh();
    this.watcher = setInterval(() => void this.refresh(), 2000);
  }

  dispose() {
    if (this.watcher) clearInterval(this.watcher);
    this.watcher = null;
  }

  async load() {
    const known = await DeviceQueries.known();
    runInAction(() => (this.devices = known));
  }

  get selected(): Device | null {
    return this.devices.find((d) => d.id === this.selectedID) ?? null;
  }

  get isProbing(): boolean {
    return this.probe.state === "running";
  }

  /** Enchufados que todavía no son parte de ningún robot (ni follower ni leader). */
  get available(): string[] {
    return this.connectedPorts.filter((port) => !this.devices.some((d) => d.id === port || d.leaderPort === port));
  }

  isConnected(id: string): boolean {
    return this.connectedPorts.includes(id);
  }

  select(id: string | null) {
    this.selectedID = id;
    Preferences.set("devices.selected", id);
  }

  async refresh() {
    let ports: string[];
    try {
      ports = await DeviceQueries.connectedPorts();
    } catch {
      return;
    }
    runInAction(() => {
      if (ports.length !== this.connectedPorts.length || ports.some((p, i) => p !== this.connectedPorts[i])) this.connectedPorts = ports;
    });
  }

  /** Agrega un SO-101: el follower (el que trabaja) y, si hay, su leader (el que mueves con la mano). */
  add(follower: string, leader: string | null) {
    this.devices = this.devices.filter((d) => d.id !== follower && d.id !== leader);
    this.devices.push(newDevice(follower, leader ?? undefined));
    this.save();
    this.select(follower);
  }

  remove(id: string) {
    this.devices = this.devices.filter((d) => d.id !== id);
    this.save();
    if (this.selectedID === id) this.select(null);
  }

  update(id: string, change: (d: Device) => void) {
    const i = this.devices.findIndex((d) => d.id === id);
    if (i < 0) return;
    const copy = toJS(this.devices[i]);
    change(copy);
    this.devices[i] = copy;
    this.save();
  }

  /** Abre el puerto, busca motores en todos los IDs (0–253) y lo cierra. */
  async test(id: string) {
    const device = this.devices.find((d) => d.id === id);
    if (!device || !this.isConnected(id) || this.isProbing) return;
    this.probe = { state: "running", progress: 0 };
    try {
      const result = await DeviceQueries.scan(device.id, device.bus, device.baud, (p) =>
        runInAction(() => {
          if (this.probe.state === "running") this.probe = { state: "running", progress: p };
        }),
      );
      runInAction(() => {
        this.update(id, (d) => {
          d.found = result;
          d.probedAt = swiftDate.now();
        });
        this.probe = { state: "idle" };
      });
    } catch (e) {
      runInAction(() => (this.probe = { state: "failed", message: e instanceof Error ? e.message : String(e) }));
    }
  }

  private save() {
    void DeviceQueries.save(toJS(this.devices));
  }
}
