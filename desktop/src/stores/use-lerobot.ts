import { makeAutoObservable, runInAction } from "mobx";
import { BridgeQueries } from "@/queries/bridge-queries";
import { CameraQueries } from "@/queries/camera-queries";
import { PermissionQueries } from "@/queries/permission-queries";
import { Files, join } from "@/queries/native";
import { Dev, type Device } from "@/types/hardware-types";
import type {
  Calibrations, CameraInfo, LeRobotEnv, PreflightCheck, RobotKind, RobotSession, SkillModel, SkillResult, SkillRun,
} from "@/types/lerobot-types";
import { AppPaths } from "@/utils/app-paths";
import { LeRobotErrors } from "@/utils/lerobot-errors";
import type { UseSettings } from "./use-settings";

type Json = Record<string, any>;

/** off · starting · ready · { failed: motivo } */
export type LeRobotStatus = "off" | "starting" | "ready" | { failed: string };

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
const num = (v: unknown, fallback = 0) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);
const numbers = (v: unknown): Record<string, number> =>
  v && typeof v === "object" ? Object.fromEntries(Object.entries(v as Json).filter(([, x]) => typeof x === "number")) : {};

function newSession(kind: string, phase: string, active: boolean): RobotSession {
  return {
    kind, phase, active, error: null, hz: 0, joints: {}, jointNames: [], units: {}, episode: 0, target: 0, elapsed: 0,
    limit: 0, targets: {}, limits: {}, playing: false, cameras: [], skillModel: null, skill: null, skillLast: null,
  };
}

/** Dos sesiones iguales (para no avisar si no cambió nada). */
const sameSession = (a: RobotSession | null, b: RobotSession) => !!a && JSON.stringify(a) === JSON.stringify(b);

/**
 * LeRobot para los robots reales: el puente, lo que hay instalado (calibraciones, cámaras) y lo que
 * corre con el robot (teleoperar, grabar, probar un modelo). Nada mueve el robot sin una orden.
 */
export class UseLeRobot {
  status: LeRobotStatus = "off";
  env: LeRobotEnv | null = null;
  calibrations: Calibrations = { robots: {}, teleoperators: {} };
  /** Los robots y leaders que trae LeRobot. */
  robotKinds: RobotKind[] = [];
  teleopKinds: RobotKind[] = [];
  cameras: CameraInfo[] = [];
  session: RobotSession | null = null;
  /** El último cuadro de la cámara principal y, en vivo, el de cada cámara («front», «cam1»…). JPEG en base64. */
  frame: string | null = null;
  frames: Record<string, string | null> = {};
  /** Avisa cada estado de una sesión (en vivo lo usa el modelo 3D que copia al robot). */
  onSession: (s: RobotSession) => void = () => {};
  error: string | null = null;

  private readonly settings: UseSettings;
  private readonly bridge = new BridgeQueries();
  private stopWatching: () => void;

  constructor(settings: UseSettings) {
    this.settings = settings;
    makeAutoObservable<UseLeRobot, "settings" | "bridge" | "stopWatching">(this, {
      settings: false, bridge: false, stopWatching: false, onSession: false,
    });
    this.bridge.onEvent = (e) => this.handle(e);
    this.stopWatching = CameraQueries.observe(() => void this.refreshCameras());
    void this.refreshCameras();
    this.bridge.onExit = (reason) =>
      runInAction(() => {
        if (this.status === "ready") this.status = { failed: reason };
        if (this.session?.active) this.session = { ...this.session, active: false, error: reason };
      });
  }

  dispose() {
    this.stopWatching();
  }

  get isBusy(): boolean {
    return this.session?.active === true;
  }

  get isReady(): boolean {
    return this.status === "ready";
  }

  /** Arranca el puente (si no está) y lee lo instalado. Tarda unos segundos la primera vez. */
  async start() {
    if (this.status === "starting" || this.bridge.isRunning) return;
    this.status = "starting";
    try {
      await this.bridge.start(this.settings.lerobotPython, this.settings.hubToken);
      runInAction(() => (this.status = "ready"));
      await this.refresh();
    } catch (e) {
      runInAction(() => (this.status = { failed: message(e) }));
    }
  }

  async refresh() {
    try {
      const hello = await this.bridge.request("hello");
      const env: LeRobotEnv = { version: hello.lerobot ?? "?", hubUser: hello.hf_user ?? null, smolvla: hello.smolvla === true };
      const kinds = await this.bridge.request("robot_types");
      const parse = (list: unknown): RobotKind[] =>
        (Array.isArray(list) ? list : []).map((k: Json) => ({
          type: k.type ?? "", port: typeof k.port === "boolean" ? k.port : true, calibration: k.calibration ?? null,
        }));
      const calib = await this.bridge.request("calibrations");
      runInAction(() => {
        this.env = env;
        this.robotKinds = parse(kinds.robots);
        this.teleopKinds = parse(kinds.teleoperators);
        this.calibrations = { robots: calib.robots ?? {}, teleoperators: calib.teleoperators ?? {} };
      });
      await this.refreshCameras();
    } catch (e) {
      runInAction(() => (this.error = message(e)));
    }
  }

  /** Vuelve a buscar cámaras (por si se enchufó una). */
  async refreshCameras() {
    const found = await CameraQueries.list();
    if (JSON.stringify(found) === JSON.stringify(this.cameras)) return;
    runInAction(() => (this.cameras = found));
    // Queda escrito qué cámaras ve la app y con qué número, para revisar si alguna no aparece.
    try {
      const line = `${new Date().toLocaleTimeString()} ${found.map((c) => `${c.index}:${c.name}`).join(", ")}\n`;
      const path = join(AppPaths.logs, "cameras.log");
      const old = (await Files.readText(path)) ?? "";
      await Files.writeText(path, old + line);
    } catch {
      /* solo es un registro */
    }
  }

  /**
   * Revisa cada pieza sin mover nada: permiso de cámara, follower, leader (si `withLeader`), poses y cámara.
   * - withCamera: si la acción usa cámaras (moverlo con el leader no).
   * - roles: al probar un modelo, el nombre que el modelo da a cada cámara (p. ej. up, side), en orden.
   */
  async preflight(d: Device, { withLeader, withCamera = true, withExtras = false, roles = [] }: {
    withLeader: boolean; withCamera?: boolean; withExtras?: boolean; roles?: string[];
  }): Promise<PreflightCheck[]> {
    await this.refreshCameras();
    if (this.status !== "ready") await this.start();
    const pre: PreflightCheck[] = [];
    if (withLeader && (d.leaderPort == null || d.leaderID == null)) {
      return [{ key: "leader", state: "fail", detail: "Choose the leader's port and calibration below." }];
    }
    let args: Json = this.base(d);
    if (withLeader) args = { ...args, ...this.leader(d) };
    const extras = withExtras ? this.extraCameras(d) : [];
    if (withCamera) {
      if (!(await PermissionQueries.camera())) {
        return [{ key: "permission", state: "fail", detail: "Curiosity doesn't have permission to use the camera. Turn it on in the system settings." }];
      }
      args.camera = this.camera(d);
      args.extra_cameras = extras.map((e) => e.index);
      if (roles.length > 1 + extras.length) {
        pre.push({
          key: "cameras", state: "fail",
          detail: `This model looks through ${roles.length} cameras (${roles.join(", ")}) and only ${1 + extras.length} is chosen.`,
        });
      }
    }
    // Cada cámara con su nombre (y el que le da el modelo), para ver exactamente qué se va a usar.
    const main = this.mainCamera(d);
    const names = [this.cameras.find((c) => c.index === main)?.name ?? "Camera", ...extras.map((e) => e.name)];
    const label = (key: string): string | null => {
      const i = key === "camera" ? 0 : key.startsWith("cam") ? Number(key.slice(3)) : NaN;
      if (!Number.isInteger(i) || i < 0 || i >= names.length) return null;
      return i < roles.length ? `${roles[i]} · ${names[i]}` : names[i];
    };
    try {
      const r = await this.bridge.request("preflight", args);
      const checks = ((r.checks as Json[]) ?? []).flatMap((c): PreflightCheck[] => {
        if (typeof c.key !== "string" || !["ok", "warn", "fail"].includes(c.state)) return [];
        return [{ key: c.key, state: c.state, detail: c.detail ?? "", label: label(c.key) }];
      });
      return [...pre, ...checks];
    } catch (e) {
      return [...pre, { key: "bridge", state: "fail", detail: LeRobotErrors.friendly(message(e)) }];
    }
  }

  /** Una foto de la cámara, para elegir la correcta (no usa el robot). JPEG en base64. */
  async snapshot(index: number): Promise<string | null> {
    try {
      const r = await this.bridge.request("snapshot", { index });
      return typeof r.jpeg === "string" ? r.jpeg : null;
    } catch (e) {
      runInAction(() => (this.error = message(e)));
      return null;
    }
  }

  /** Datasets en esas carpetas (crudo, para UseDatasets). */
  async datasets(roots: string[]): Promise<Json[]> {
    const r = await this.bridge.request("datasets", { roots });
    return (r.datasets as Json[]) ?? [];
  }

  request(cmd: string, args: Json = {}): Promise<Json> {
    return this.bridge.request(cmd, args);
  }

  // ---------- Con el robot ----------

  /** El follower copia al leader. */
  async teleoperate(d: Device) {
    await this.startSession("teleop", { ...this.base(d), ...this.leader(d), fps: 60 });
  }

  /** Graba demostraciones con el leader en un dataset de la app. */
  async record(d: Device, dataset: string, task: string, episodes: number, episodeSeconds: number, resetSeconds: number) {
    await this.refreshCameras();
    const root = join(AppPaths.datasets, dataset);
    await this.startSession("record", {
      ...this.base(d), ...this.leader(d),
      camera: this.camera(d), repo_id: `local/${dataset}`, root, task,
      num_episodes: episodes, episode_time_s: episodeSeconds, reset_time_s: resetSeconds,
    });
  }

  /** El robot usa un modelo entrenado durante `seconds`. */
  async runPolicy(d: Device, modelPath: string, task: string, seconds: number) {
    await this.refreshCameras();
    await this.startSession("rollout", {
      ...this.base(d),
      camera: this.camera(d), extra_cameras: this.extraCameras(d).map((e) => e.index), policy_path: modelPath, task, duration: seconds,
      max_relative_target: 10,
    });
  }

  /** En vivo: el follower se queda firme y va a los objetivos que se le manden (sin leader). */
  async live(d: Device) {
    await this.refreshCameras();
    await this.startSession("live", { ...this.base(d), camera: this.camera(d), extra_cameras: this.extraCameras(d).map((e) => e.index) });
  }

  async liveTargets(targets: Record<string, number>) {
    await this.bridge.request("live_targets", { targets });
  }
  async liveCameras(indexes: number[]) {
    await this.bridge.request("live_cameras", { extra_cameras: indexes });
  }
  /** Reproduce una trayectoria ([[t, articulaciones…]] en grados) a `speed` de su velocidad. */
  async liveTrajectory(points: number[][], speed: number) {
    await this.bridge.request("live_trajectory", { points, speed });
  }
  async liveHome() {
    await this.bridge.request("live_home");
  }

  /** Carga un modelo de órdenes (carpeta local o id del Hub) en la sesión en vivo. Tarda la primera vez. */
  async liveSkillLoad(path: string) {
    await this.bridge.request("live_skill_load", { policy_path: path });
  }
  /** El modelo hace `instruction` durante `seconds` como mucho (los controles o «parar» lo cortan). */
  async liveSkill(instruction: string, seconds: number) {
    await this.bridge.request("live_skill", { instruction, seconds });
  }
  async liveSkillStop() {
    await this.bridge.request("live_skill_stop");
  }

  /** Una foto grande de cada cámara mientras está en vivo (para la IA): [(cámara, JPEG base64)]. */
  async liveLook(): Promise<{ camera: string; jpeg: string }[]> {
    const r = await this.bridge.request("live_look");
    const photos = ((r.images as Json[]) ?? []).flatMap((i) =>
      typeof i.camera === "string" && typeof i.jpeg === "string" ? [{ camera: i.camera as string, jpeg: i.jpeg as string }] : [],
    );
    if (photos.length === 0) throw new Error("The cameras didn't send an image.");
    return photos;
  }

  /** Demostraciones en la simulación: el leader real mueve el robot simulado; el follower no se conecta. */
  async simRecord(d: Device, dataset: string, task: string, episodes: number, episodeSeconds: number, resetSeconds: number) {
    const root = join(AppPaths.datasets, dataset);
    await this.startSession("simrecord", {
      ...this.leader(d),
      follower_id: d.followerID ?? "", repo_id: `local/${dataset}`, root, task,
      num_episodes: episodes, episode_time_s: episodeSeconds, reset_time_s: resetSeconds, fps: 30,
    });
  }

  /** Un cuadro de la simulación para la grabación: la imagen de su cámara (JPEG base64) y su estado (grados; pinza 0-100). */
  async simFrame(jpeg: string, state: Record<string, number>) {
    try {
      await this.bridge.request("sim_frame", { jpeg, state });
    } catch {
      /* se pierde un cuadro */
    }
  }

  next() {
    this.bridge.request("next").catch(() => {});
  }
  redo() {
    this.bridge.request("redo").catch(() => {});
  }
  stop() {
    this.bridge.request("stop").catch(() => {});
  }

  // ---------- Interno ----------

  private base(d: Device): Json {
    return { robot_type: Dev.robotKind(d) ?? "", follower_port: d.id, follower_id: d.followerID ?? "" };
  }
  private leader(d: Device): Json {
    return { teleop_type: Dev.teleopKind(d) ?? "", leader_port: d.leaderPort ?? "", leader_id: d.leaderID ?? "" };
  }

  /** Las calibraciones guardadas para el tipo de robot y de leader de este dispositivo. */
  followers(d: Device): string[] {
    const folder = this.robotKinds.find((k) => k.type === Dev.robotKind(d))?.calibration;
    return (folder && this.calibrations.robots[folder]) || [];
  }
  leaders(d: Device): string[] {
    const folder = this.teleopKinds.find((k) => k.type === Dev.teleopKind(d))?.calibration;
    return (folder && this.calibrations.teleoperators[folder]) || [];
  }
  private camera(d: Device): Json {
    return { index: this.mainCamera(d) ?? 0, width: 640, height: 480, fps: 30 };
  }

  /** El número actual de la cámara principal. Se busca por nombre: el sistema renumera las cámaras al enchufar otra. */
  mainCamera(d: Device): number | null {
    return this.cameras.find((c) => c.name === d.cameraName)?.index ?? d.cameraIndex ?? null;
  }

  /** Las cámaras extra enchufadas ahora, con su número actual (sin repetir la principal). */
  extraCameras(d: Device): { name: string; index: number }[] {
    const main = this.mainCamera(d);
    return Dev.extraNames(d).flatMap((name) => {
      const c = this.cameras.find((c) => c.name === name && c.index !== main);
      return c ? [{ name, index: c.index }] : [];
    });
  }

  private async startSession(kind: string, args: Json) {
    this.error = null;
    this.frame = null;
    this.frames = {};
    if (this.status !== "ready") await this.start();
    if (this.status !== "ready") return;
    runInAction(() => (this.session = newSession(kind, "starting", true)));
    try {
      await this.bridge.request(kind, args);
    } catch (e) {
      runInAction(() => {
        this.session = null;
        this.error = message(e);
      });
    }
  }

  private handle(e: Json) {
    const kind = e.event;
    if (typeof kind !== "string") return;
    if (kind === "frame") {
      const data = typeof e.jpeg === "string" ? e.jpeg : null;
      const camera = typeof e.camera === "string" ? e.camera : "front";
      this.frames = { ...this.frames, [camera]: data };
      if (camera === "front") this.frame = data;
      return;
    }
    if (!["teleop", "record", "rollout", "live", "simrecord"].includes(kind)) return;
    const s = newSession(kind, typeof e.phase === "string" ? e.phase : "", e.active === true);
    s.error = typeof e.error === "string" ? e.error : null;
    s.hz = num(e.hz);
    s.joints = numbers(e.joints);
    s.episode = Math.trunc(num(e.episode));
    s.target = Math.trunc(num(e.target));
    s.elapsed = num(e.elapsed);
    s.limit = num(e.limit);
    s.targets = numbers(e.targets);
    s.playing = e.playing === true;
    s.cameras = Array.isArray(e.cameras) ? e.cameras : [];
    s.jointNames = Array.isArray(e.joint_names) ? e.joint_names : [];
    s.units = e.units && typeof e.units === "object" ? e.units : {};
    const m = e.skill_model;
    if (m && typeof m.path === "string") {
      s.skillModel = { path: m.path, type: m.type ?? "", device: m.device ?? "", note: m.note ?? null } satisfies SkillModel;
    }
    const k = e.skill;
    if (k && typeof k.instruction === "string") {
      s.skill = { instruction: k.instruction, elapsed: num(k.elapsed), limit: num(k.limit) } satisfies SkillRun;
    }
    const l = e.skill_last;
    if (l && typeof l.instruction === "string") {
      s.skillLast = { instruction: l.instruction, reason: l.reason ?? "", seconds: num(l.seconds) } satisfies SkillResult;
    }
    const limits: Record<string, [number, number]> = {};
    for (const [j, v] of Object.entries((e.limits as Json) ?? {})) {
      if (Array.isArray(v) && v.length === 2 && typeof v[0] === "number" && typeof v[1] === "number" && v[0] <= v[1]) limits[j] = [v[0], v[1]];
    }
    s.limits = limits;
    if (!sameSession(this.session, s)) {
      this.session = s;
      this.onSession(s);
    }
    // Si terminó por un error, que se vea y diga qué hacer.
    if (!s.active && s.error) this.error = LeRobotErrors.friendly(s.error);
  }
}
