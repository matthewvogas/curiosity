import { makeAutoObservable } from "mobx";
import { Files } from "@/queries/native";
import { AppPaths } from "@/utils/app-paths";
import { Naming } from "@/utils/naming";
import { JointUnits } from "@/utils/joint-units";
import type { UseLeRobot } from "@/stores/use-lerobot";
import type { UseSimulation } from "@/stores/use-simulation";
import type { Device } from "@/types/hardware-types";
import type { JointInfo } from "@/types/robot-types";
import type { RobotSession } from "@/types/lerobot-types";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Grabar demostraciones en la simulación con el leader real: el leader mueve el robot simulado (por nombre de
 * articulación) y la cámara de la simulación y su estado van al dataset (como lerobot-record, sin el brazo real).
 */
export class UseSimRecording {
  /** Cada vuelta del bucle tiene su número: empezar otra grabación corta la anterior. */
  private pump = 0;

  constructor(private lerobot: UseLeRobot, private simulation: UseSimulation) {
    makeAutoObservable<UseSimRecording, "lerobot" | "simulation" | "pump">(this, { lerobot: false, simulation: false, pump: false });
  }

  get session(): RobotSession | null {
    const s = this.lerobot.session;
    return s?.kind === "simrecord" ? s : null;
  }

  get isActive(): boolean {
    return this.session?.active === true;
  }

  /** Hace falta un robot abierto con articulaciones; las del leader se emparejan por nombre al empezar. */
  get canRecord(): boolean {
    return (this.simulation.model?.joints.length ?? 0) > 0;
  }

  /** Las articulaciones del leader que el robot simulado no tiene (no se pueden copiar). */
  get unmatched(): string[] {
    const s = this.session;
    if (!s) return [];
    const names = new Set((this.simulation.model?.joints ?? []).map((j: JointInfo) => j.name));
    return s.jointNames.filter((j) => !names.has(j));
  }

  async start(leader: Device, task: string, episodes: number, seconds: number, reset: number) {
    const onDisk = await Files.list(AppPaths.datasets).catch(() => []);
    const taken = new Set(onDisk.map((e) => e.name));
    const dataset = Naming.unique("sim_" + Naming.slug(task), taken);
    if (this.simulation.state.paused) this.simulation.togglePause();
    await this.lerobot.simRecord(leader, dataset, task, episodes, seconds, reset);
    const run = ++this.pump;
    void this.loop(run);
  }

  next() {
    this.lerobot.next();
  }
  redo() {
    this.lerobot.redo();
  }
  stop() {
    this.lerobot.stop();
  }

  /** Mientras graba: el robot simulado sigue al leader y cada cuadro de su cámara va al puente. */
  private async loop(run: number) {
    await sleep(300);
    const camera = this.simulation.model?.cameras[0] ?? null;
    for (;;) {
      const s = this.session;
      if (run !== this.pump || !s || !(s.active || s.phase === "starting")) return;
      const ranges = new Map<string, JointInfo>();
      for (const j of this.simulation.model?.joints ?? []) if (!ranges.has(j.name)) ranges.set(j.name, j);
      for (const [j, v] of Object.entries(s.joints)) {
        const info = ranges.get(j);
        if (!info) continue;
        const q = JointUnits.toModel(v, s.units[j] ?? "deg", info.lower ?? null, info.upper ?? null);
        if (q != null) this.simulation.setTarget(j, q);
      }
      let jpeg: string | null = null;
      if (s.phase === "recording") {
        try {
          jpeg = await this.simulation.capture(camera);
        } catch {
          jpeg = null;
        }
      }
      if (jpeg != null) {
        // El estado en las unidades del leader; una articulación que el modelo no tiene queda en 0.
        const positions = new Map<string, number>();
        for (const j of this.simulation.state.joints) if (!positions.has(j.name)) positions.set(j.name, j.q);
        const state: Record<string, number> = {};
        for (const j of s.jointNames) {
          const q = positions.get(j);
          const info = ranges.get(j);
          const v = q != null && info ? JointUnits.fromModel(q, s.units[j] ?? "deg", info.lower ?? null, info.upper ?? null) : null;
          state[j] = v ?? 0;
        }
        await this.lerobot.simFrame(jpeg, state);
      } else {
        await sleep(33);
      }
    }
  }
}
