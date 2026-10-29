import { makeAutoObservable, runInAction } from "mobx";
import { Preferences } from "@/queries/preferences";
import { RobotQueries } from "@/queries/robot-queries";
import { SimulationQueries } from "@/queries/simulation-queries";
import { Dev, type CameraFit, type Device } from "@/types/hardware-types";
import type { ChatBody, ChatToolOutput, Photo } from "@/types/chat-types";
import type { SkillModel, SkillResult, SkillRun } from "@/types/lerobot-types";
import { jointOrder } from "@/types/knowledge-types";
import type { Robot } from "@/types/robot-types";
import { AgentTools } from "@/utils/agent-tools";
import { CameraCalibration, type CalibrationPair } from "@/utils/camera-calibration";
import { swiftDate } from "@/utils/codable";
import { ImageGrid } from "@/utils/image-grid";
import { JointUnits } from "@/utils/joint-units";
import { KnowledgePrompt, swiftNumber } from "@/utils/knowledge-prompt";
import { RealAgentTools, type JointLimits } from "@/utils/real-agent-tools";
import { RobotNotes } from "@/utils/robot-notes";
import { LiveArm, armProblemMessage, type ArmProblem } from "./live-arm";
import type { UseKnowledge } from "./use-knowledge";
import type { UseLeRobot } from "./use-lerobot";

type Json = Record<string, any>;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const message = (e: unknown) => (e instanceof Error ? e.message : String(e));
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Una cámara en vivo: su clave en el puente («front», «cam1»…), su nombre y su último cuadro (JPEG base64). */
export type LiveCamera = { key: string; name: string; frame: string | null };

/**
 * El robot real en vivo: conectarlo (se queda firme), moverlo con los controles o con la IA, y soltarlo
 * (vuelve a su pose del principio). Tiene un gemelo 3D que copia su pose, ve por todas sus cámaras y es
 * también el cuerpo del chat con el robot real.
 */
export class UseLiveRobot implements ChatBody {
  readonly lerobot: UseLeRobot;
  /** El modelo 3D del robot (el que se eligió en sus ajustes), quieto, puesto en la misma pose que el real. */
  readonly twin = new SimulationQueries();
  device: Device | null = null;
  /** Calibrando una cámara (su nombre) y los pares marcados hasta ahora (ver live-arm). */
  calibrating: string | null = null;
  calibrationPairs: CalibrationPair[] = [];
  /** Lo que está haciendo el brazo solo (una habilidad o ir a un punto) y el último problema. */
  armBusy: string | null = null;
  armError: string | null = null;
  /** El tamaño de la última foto que vio la IA por cada cámara (para pasar sus píxeles a la mesa). */
  lookSizes: Record<string, { width: number; height: number }> = {};
  skillLoading = false;
  skillError: string | null = null;
  /** Si la IA del chat puede usar el modelo (run_skill) o solo se prueba a mano. */
  skillForAI = Preferences.get("live.skillForAI", true);

  static readonly calibrationPoints = LiveArm.calibrationPoints;

  private readonly knowledge: UseKnowledge;
  /** Objetivos de los deslizadores aún sin mandar (se juntan para no saturar el puente). */
  private outgoing: Record<string, number> = {};
  private flushing = false;
  private twinLoaded = false;
  private twinModelID: string | null = null;
  /** Los modelos 3D que se pueden elegir (incluidos e importados), para encontrar el del robot. */
  private models: Robot[] = [];
  /** El rango de cada articulación del modelo 3D, para llevar ahí lo que no va en grados. */
  private twinRanges: Record<string, { lower: number | null; upper: number | null }> = {};
  /** Los últimos movimientos (antes, después y cuánto cambió), para que la IA entienda cómo responde. */
  private moves: Json[] = [];

  constructor(lerobot: UseLeRobot, knowledge: UseKnowledge) {
    this.lerobot = lerobot;
    this.knowledge = knowledge;
    makeAutoObservable<UseLiveRobot, "knowledge" | "twinLoaded" | "twinModelID" | "twinRanges" | "moves" | "flushing">(this, {
      lerobot: false, twin: false, knowledge: false, twinLoaded: false, twinModelID: false, twinRanges: false, moves: false, flushing: false,
    });
    void this.loadModels();
    this.twin.onAttach = () => void this.loadTwin();
    this.twin.onMessage = (m) => {
      if (m.type !== "model") return;
      this.twin.pause(true); // sin física: solo copia la pose
      const ranges: Record<string, { lower: number | null; upper: number | null }> = {};
      for (const j of (m.joints as Json[]) ?? []) {
        if (typeof j.name === "string" && !(j.name in ranges)) ranges[j.name] = { lower: num(j.lower), upper: num(j.upper) };
      }
      this.twinRanges = ranges;
      this.twinLoaded = true;
      this.mirror(this.lerobot.session?.joints ?? {}, this.lerobot.session?.units ?? {});
    };
    // El modelo 3D copia al robot en vivo y también mientras prueba un modelo. La IA usa sus articulaciones.
    lerobot.onSession = (s) => {
      if (s.kind !== "live" && s.kind !== "rollout") return;
      if (s.jointNames.length > 0) {
        RealAgentTools.joints = s.jointNames;
        RealAgentTools.units = s.units;
      }
      this.mirror(s.joints, s.units);
    };
  }

  private async loadModels() {
    const [bundled, imported] = await Promise.all([RobotQueries.bundled(), RobotQueries.imported()]).catch(() => [[], []] as Robot[][]);
    runInAction(() => (this.models = [...bundled, ...imported]));
  }

  /** Las cámaras en vivo, con su nombre: la principal primero. */
  get cameras(): LiveCamera[] {
    const device = this.device;
    if (!this.isLive || !device) return [];
    const out: LiveCamera[] = [{ key: "front", name: device.cameraName ?? "Main", frame: this.lerobot.frames["front"] ?? null }];
    this.lerobot.extraCameras(device).forEach((extra, i) => {
      out.push({ key: `cam${i + 1}`, name: extra.name, frame: this.lerobot.frames[`cam${i + 1}`] ?? null });
    });
    return out;
  }

  private label(key: string): string {
    return this.cameras.find((c) => c.key === key)?.name ?? key;
  }

  /** El modelo 3D que se eligió para este robot (de los incluidos o importados); sin ninguno no hay gemelo. */
  get hasTwin(): boolean {
    return this.twinModel != null;
  }

  private get twinModel(): Robot | null {
    const id = this.device ? Dev.model(this.device) : null;
    if (!id) return null;
    return this.models.find((r) => r.id === id) ?? null;
  }

  private async loadTwin() {
    this.twinLoaded = false;
    if (this.models.length === 0) await this.loadModels();
    const robot = this.twinModel;
    if (!robot) return;
    this.twinModelID = robot.id;
    const profile = await RobotQueries.readProfile(RobotQueries.filePath(robot));
    profile.scene = { objects: [] }; // solo el robot, sin los objetos de la escena
    this.twin.load(SimulationQueries.modelURL(robot), profile);
  }

  /** Una posición de LeRobot → la del modelo 3D (null si el modelo no tiene esa articulación). */
  toTwin(joint: string, value: number): number | null {
    const range = this.twinRanges[joint];
    if (!range) return null;
    return JointUnits.toModel(value, this.lerobot.session?.units[joint] ?? RealAgentTools.units[joint] ?? "deg", range.lower, range.upper);
  }

  /** Una posición del modelo 3D → la de LeRobot. */
  fromTwin(joint: string, q: number): number | null {
    const range = this.twinRanges[joint];
    if (!range) return null;
    return JointUnits.fromModel(q, this.lerobot.session?.units[joint] ?? RealAgentTools.units[joint] ?? "deg", range.lower, range.upper);
  }

  /** Las posiciones de LeRobot → las del modelo 3D, por nombre de articulación (las que no tiene se ignoran). */
  mirror(joints: Record<string, number>, units?: Record<string, string>) {
    if (!this.twinLoaded || Object.keys(joints).length === 0) return;
    const u = units ?? this.lerobot.session?.units ?? {};
    const q: Record<string, number> = {};
    for (const [j, value] of Object.entries(joints)) {
      const range = this.twinRanges[j];
      if (!range) continue;
      const v = JointUnits.toModel(value, u[j] ?? "deg", range.lower, range.upper);
      if (v != null) q[j] = v;
    }
    if (Object.keys(q).length > 0) this.twin.setTargets(q, true);
  }

  get isLive(): boolean {
    return this.lerobot.session?.kind === "live" && this.lerobot.session?.active === true;
  }
  get isReturning(): boolean {
    return this.isLive && this.lerobot.session?.phase === "returning";
  }
  get isReady(): boolean {
    return this.isLive && this.lerobot.session?.phase === "running";
  }
  get joints(): Record<string, number> {
    return this.isLive ? this.lerobot.session?.joints ?? {} : {};
  }
  get targets(): Record<string, number> {
    return this.isLive ? { ...(this.lerobot.session?.targets ?? {}), ...this.outgoing } : {};
  }
  get limits(): JointLimits {
    return this.isLive ? this.lerobot.session?.limits ?? {} : {};
  }

  /** Las cámaras extra cambiaron mientras está en vivo (para nombrarlas bien). */
  update(device: Device) {
    this.device = device;
  }

  async start(device: Device) {
    this.device = device;
    if (this.twinModelID != null && this.twinModelID !== Dev.model(device)) void this.loadTwin();
    this.moves = [];
    await this.lerobot.live(device);
  }

  stop() {
    this.lerobot.stop();
  }

  /** Desde un deslizador: el último valor de cada articulación, como mucho cada 50 ms. */
  setTarget(joint: string, value: number) {
    this.outgoing = { ...this.outgoing, [joint]: value };
    if (this.flushing) return;
    this.flushing = true;
    setTimeout(() => {
      const batch = this.outgoing;
      runInAction(() => (this.outgoing = {}));
      this.flushing = false;
      this.lerobot.liveTargets(batch).catch(() => {});
    }, 50);
  }

  /** Cambia las cámaras extra sin desconectar el robot. */
  setExtraCameras(device: Device) {
    this.device = device;
    const indexes = this.lerobot.extraCameras(device).map((e) => e.index);
    this.lerobot.liveCameras(indexes).catch(() => {});
  }

  home() {
    this.lerobot.liveHome().catch(() => {});
  }

  // ---------- Modelo de órdenes (la IA dice «qué», el modelo hace el «cómo») ----------

  get skillModel(): SkillModel | null {
    return this.isLive ? this.lerobot.session?.skillModel ?? null : null;
  }
  get skillRun(): SkillRun | null {
    return this.isLive ? this.lerobot.session?.skill ?? null : null;
  }
  get skillLast(): SkillResult | null {
    return this.isLive ? this.lerobot.session?.skillLast ?? null : null;
  }

  setSkillForAI(on: boolean) {
    this.skillForAI = on;
    Preferences.set("live.skillForAI", on);
  }

  async loadSkill(path: string) {
    const p = path.trim();
    if (!p) return;
    this.skillLoading = true;
    this.skillError = null;
    try {
      await this.lerobot.liveSkillLoad(p);
    } catch (e) {
      runInAction(() => (this.skillError = message(e)));
    } finally {
      runInAction(() => (this.skillLoading = false));
    }
  }

  /** Corre una orden y espera a que termine (por tiempo, al pararla o si la cortan los controles). */
  async runSkill(instruction: string, seconds: number, signal?: AbortSignal): Promise<SkillResult | null> {
    this.skillError = null;
    const before = JSON.stringify(this.skillLast);
    try {
      await this.lerobot.liveSkill(instruction, seconds);
    } catch (e) {
      runInAction(() => (this.skillError = message(e)));
      throw e;
    }
    // El primer aviso puede tardar: el modelo piensa su primer tramo antes de que el bucle avise.
    const deadline = Date.now() + (seconds + 20) * 1000;
    let started = false;
    while (this.isLive && Date.now() < deadline) {
      if (signal?.aborted) {
        this.stopSkill();
        break;
      }
      if (this.skillRun != null) {
        started = true;
      } else {
        const last = this.skillLast;
        if (last && (started || JSON.stringify(last) !== before)) return last;
      }
      await sleep(150);
    }
    return this.skillLast;
  }

  stopSkill() {
    this.lerobot.liveSkillStop().catch(() => {});
  }

  /** El estado para la IA: articulaciones y dónde quedó la pinza (cinemática directa del modelo 3D). */
  private async pose(): Promise<Json> {
    const out = RealAgentTools.describe(this.joints, this.targets, this.limits);
    if (this.twinLoaded) await sleep(150); // que el gemelo alcance la última pose
    if (this.twinLoaded) {
      try {
        const fresh = await this.twin.linkPositions();
        const g = fresh["gripper_frame_link"] ?? fresh["gripper_link"];
        if (g) out.gripper_cm = g.map((v) => Math.round(v * 1000) / 10);
        const w = fresh["wrist_link"];
        if (w) out.wrist_cm = w.map((v) => Math.round(v * 1000) / 10);
      } catch {
        /* sin cinemática esta vez */
      }
    }
    return out;
  }

  private clamp(batch: Record<string, number>): [Record<string, number>, string[]] {
    const out: Record<string, number> = {};
    const clipped: string[] = [];
    const limits = this.limits;
    for (const [j, v] of Object.entries(batch)) {
      const range = limits[j];
      if (!range) continue;
      const value = Math.min(range[1], Math.max(range[0], v));
      if (value !== v) clipped.push(j);
      out[j] = value;
    }
    return [out, clipped];
  }

  /** Espera a que el robot llegue a sus objetivos (o termine de reproducir, o se acabe el tiempo). */
  async settle(timeout: number, waitPlayback = false) {
    const deadline = Date.now() + timeout * 1000;
    await sleep(400);
    while (waitPlayback && Date.now() < deadline && this.isLive && this.lerobot.session?.playing === true) await sleep(200);
    while (Date.now() < deadline && this.isLive) {
      const t = this.targets, q = this.joints;
      if (RealAgentTools.joints.every((j) => Math.abs((q[j] ?? 0) - (t[j] ?? 0)) < 3)) break;
      await sleep(200);
    }
  }

  // ---------- El brazo (live-arm) ----------

  /** Cuánto está abierta la pinza, de 0 a 100 %, sea cual sea su escala en LeRobot. */
  private gripperPercent(v: number): number {
    switch (this.lerobot.session?.units["gripper"]) {
      case "±100":
        return (v + 100) / 2;
      case "deg": {
        const r = this.limits["gripper"];
        return r ? (r[1] > r[0] ? ((v - r[0]) / (r[1] - r[0])) * 100 : 0) : v;
      }
      default:
        return v;
    }
  }

  /** La calibración guardada de una cámara (por su nombre), si hay. */
  calibration(cameraName: string): CameraFit | null {
    return this.device?.cameraCalibrations?.[cameraName] ?? null;
  }

  startCalibration(cameraName: string) {
    this.calibrating = cameraName;
    this.calibrationPairs = [];
    this.armError = null;
  }

  cancelCalibration() {
    this.calibrating = null;
    this.calibrationPairs = [];
  }

  /** Lleva la pinza (cerrada) al punto `index` de la calibración. El clic en «Move» es la aprobación. */
  async moveToCalibrationPoint(index: number) {
    const point = LiveArm.calibrationPoints[index];
    if (!point) return;
    await this.lerobot.liveTargets({ gripper: 0 }).catch(() => {});
    await this.runArmSkill({ type: "reach", point }, `Moving to point ${index + 1}…`);
  }

  /** La persona marcó dónde ve la punta (0…1): se junta con dónde está según la cinemática. */
  async markCalibration(x: number, y: number) {
    if (this.calibrating == null) return;
    this.mirror(this.joints);
    await sleep(150); // que el gemelo copie la pose actual
    let tip: number[] | null = null;
    try {
      tip = await this.twin.tip();
    } catch {
      tip = null;
    }
    runInAction(() => {
      if (!tip) this.armError = "The 3D model isn't ready.";
      else this.calibrationPairs.push({ point: tip, pixel: [x, y] });
    });
  }

  undoCalibrationPoint() {
    if (this.calibrationPairs.length > 0) this.calibrationPairs.pop();
  }

  /** El ajuste con los puntos marcados hasta ahora (null con menos de 6). */
  get calibrationFit(): CameraFit | null {
    const s = CameraCalibration.solve(this.calibrationPairs);
    return s ? { matrix: s.matrix, errorPx: s.error * 640, points: this.calibrationPairs.length, date: swiftDate.now() } : null;
  }

  /** Pasa los límites de la calibración del robot al gemelo (en sus unidades, con JointUnits). */
  private syncLimits() {
    const out: Record<string, number[]> = {};
    for (const [j, r] of Object.entries(this.limits)) {
      const lo = this.toTwin(j, r[0]), hi = this.toTwin(j, r[1]);
      if (lo != null && hi != null) out[j] = [Math.min(lo, hi), Math.max(lo, hi)];
    }
    this.twin.setLimits(out);
  }

  /** Planifica en el gemelo y, si se alcanza, el robot hace la trayectoria entera. Devuelve cómo salió. */
  async runArmSkill(spec: Json, busy: string): Promise<Json> {
    if (!this.isReady) return { done: false, message: "The robot isn't live." };
    this.armBusy = busy;
    this.armError = null;
    const fail = (msg: string) => runInAction(() => (this.armError = msg));
    try {
      this.syncLimits();
      this.mirror(this.joints);
      await sleep(150);
      const names = RealAgentTools.joints;
      let plan: Json;
      try {
        plan = await this.twin.planSkill(spec, names, LiveArm.armSpeed);
      } catch (e) {
        fail(message(e));
        return { done: false, message: message(e) };
      }
      const rows = plan.rows;
      if (plan.ok !== true || !Array.isArray(rows)) {
        runInAction(() => (this.armError = typeof plan.message === "string" ? plan.message : null));
        return { done: false, reason: plan.reason ?? "no_plan", message: plan.message ?? "Couldn't plan the move." };
      }
      // Posiciones del modelo → unidades de LeRobot de cada articulación.
      const points = (rows as number[][]).map((row) => [
        Number(row[0]),
        ...names.map((j, i) => this.fromTwin(j, Number(row[i + 1])) ?? this.joints[j] ?? 0),
      ]);
      const seconds = num(plan.seconds) ?? 5;
      try {
        await this.lerobot.liveTrajectory(points, 1);
      } catch (e) {
        fail(message(e));
        return { done: false, message: message(e) };
      }
      await this.settle(seconds + 6, true);
      const out: Json = { done: true, seconds, reach_error_cm: plan.reach_error_cm ?? 0 };
      const g = this.joints["gripper"] ?? 0;
      out.gripper = Math.round(g);
      if (spec.type !== "reach") {
        // Lo que siente la pinza: si se mandó cerrar y quedó abierta, hay algo adentro.
        const closing = this.gripperPercent(this.targets["gripper"] ?? 100) < 10;
        out.holding = closing && this.gripperPercent(g) > LiveArm.emptyGrip;
      }
      return out;
    } finally {
      runInAction(() => (this.armBusy = null));
    }
  }

  /** De un píxel de una foto de la IA (con su tamaño) al punto de la mesa, con la calibración de esa cámara. */
  tablePoint(camera: string, x: number, y: number, height: number): { ok: true; point: number[] } | { ok: false; problem: ArmProblem } {
    const fit = this.calibration(camera);
    if (!fit) return { ok: false, problem: { kind: "notCalibrated", camera } };
    const size = this.lookSizes[camera];
    if (!size) return { ok: false, problem: { kind: "noPicture", camera } };
    const p = CameraCalibration.point(fit.matrix, [x / size.width, y / size.height], height);
    if (!p) return { ok: false, problem: { kind: "offTable" } };
    return { ok: true, point: p };
  }

  // ---------- ChatBody: el cuerpo del chat con el robot real ----------

  get chatTools(): Json[] {
    return [
      ...RealAgentTools.definitions,
      ...(this.knowledge.active == null ? [] : [...KnowledgePrompt.liveTools, RealAgentTools.lookReferences]),
      ...(this.skillModel != null && this.skillForAI ? [RealAgentTools.runSkill] : []),
      ...RealAgentTools.armTools,
    ];
  }

  get chatNotReady(): string {
    return "Connect the robot live to talk to it.";
  }

  /** Lo que el gemelo mide del brazo (pinza, alcance) y qué cámaras están calibradas, para las notas del robot. */
  async chatRobotFacts(): Promise<string[] | null> {
    const effector = this.twinLoaded ? await this.twin.call<Json | null>("effector").catch(() => null) : null;
    const cameras = this.cameras.map((c) => ({ name: c.name, live: true, calibratedErrorPx: this.calibration(c.name)?.errorPx ?? null }));
    return RobotNotes.factsLines(effector, cameras);
  }

  chatSystemPrompt(robotName: string): string | null {
    if (!this.isReady) return null;
    const calibrated = this.cameras.map((c) => c.name).filter((n) => this.calibration(n) != null);
    const active = this.knowledge.active;
    const skill = this.skillModel;
    return (
      RealAgentTools.systemPrompt(robotName, this.limits, calibrated) +
      (active ? KnowledgePrompt.liveSection(active) : "") +
      (this.skillForAI && skill ? RealAgentTools.skillSection(skill) : "")
    );
  }

  chatTitle(name: string, input: Json): string {
    switch (name) {
      case "go_to_pose": return `Go to "${input.name ?? ""}"`;
      case "play_segment": return `Play "${input.name ?? ""}"`;
      case "look_references": return "Looking at the demonstration pictures";
      case "pick": return "Pick up";
      case "place": return "Put it down";
      case "gripper": return input.open ?? true ? "Open the gripper" : "Close the gripper";
      default: return RealAgentTools.title(name);
    }
  }

  chatApproval(name: string, input: Json): string | null {
    const offsets = UseLiveRobot.offsets(input);
    const entries = Object.entries(offsets);
    const extra = entries.length === 0
      ? ""
      : "\nAdjustments: " + entries.map(([j, d]) => `${j} ${d >= 0 ? "+" : ""}${RealAgentTools.format(d, j)}`).join(", ");
    switch (name) {
      case "go_to_pose": {
        const pose = this.knowledge.active?.poses.find((p) => p.name === input.name);
        if (!pose) return null;
        return (
          RealAgentTools.joints
            .map((j) => `${j}: ${RealAgentTools.format(this.joints[j] ?? 0, j)} → ${RealAgentTools.format((pose.joints[j] ?? 0) + (offsets[j] ?? 0), j)}`)
            .join("\n") + extra
        );
      }
      case "play_segment": {
        const s = this.knowledge.active?.segments.find((x) => x.name === input.name);
        if (!s) return null;
        const speed = UseLiveRobot.speed(input);
        return `Demonstration ${s.episode}, from ${swiftNumber(s.from)} to ${swiftNumber(s.to)} s, at ${Math.trunc(speed * 100)}% of its speed${s.note ? ` (${s.note})` : ""}.` + extra;
      }
      case "pick":
      case "place": {
        const x = num(input.x) ?? 0, y = num(input.y) ?? 0;
        const camera = typeof input.camera === "string" ? input.camera : "";
        const h = (num(input[name === "pick" ? "height_cm" : "surface_cm"]) ?? 0) / 100;
        const r = this.tablePoint(camera, x, y, h);
        const spot = r.ok ? ` → table point (${Math.round(r.point[0] * 100)}, ${Math.round(r.point[1] * 100)}) cm` : "";
        return (name === "pick" ? "The arm picks up what's at" : "The arm puts it down at") + ` pixel (${Math.trunc(x)}, ${Math.trunc(y)}) of ${camera}${spot}, in one continuous move.`;
      }
      case "gripper":
        return input.open ?? true ? "Open the gripper." : "Close the gripper.";
      default:
        return RealAgentTools.approval(name, input, this.joints);
    }
  }

  private static offsets(input: Json): Record<string, number> {
    const out: Record<string, number> = {};
    for (const o of (input.offsets as Json[]) ?? []) {
      const d = num(o.delta);
      if (typeof o.joint === "string" && d != null && d !== 0) out[o.joint] = d;
    }
    return out;
  }

  private static speed(input: Json): number {
    return Math.min(1, Math.max(0.25, num(input.speed) ?? 0.5));
  }

  /** La foto de una cámara calibrada va con cuadrícula y su tamaño, para poder señalar en ella. */
  private async gridded(camera: string, jpeg: string): Promise<Photo> {
    if (this.calibration(camera) == null) return { label: camera, jpeg };
    const g = await ImageGrid.draw(jpeg);
    if (!g) return { label: camera, jpeg };
    runInAction(() => (this.lookSizes = { ...this.lookSizes, [camera]: { width: g.width, height: g.height } }));
    return { label: `${camera} (${g.width}×${g.height} px, calibrated: you can point in it)`, jpeg: g.jpeg };
  }

  /** Mueve a `batch` y devuelve el antes y el después (como move_joints). */
  private async perform(batch: Record<string, number>, clipped: string[] = [], play?: () => Promise<number>): Promise<ChatToolOutput> {
    const before = await this.pose();
    const start = this.joints;
    if (play) {
      const duration = await play();
      await this.settle(duration + 3, true);
    } else {
      await this.lerobot.liveTargets(batch);
      const longest = Math.max(0, ...Object.entries(batch).map(([j, v]) => Math.abs(v - (start[j] ?? v))));
      await this.settle(longest / 40 + 2);
    }
    const after = await this.pose();
    const move = RealAgentTools.move(batch, start, this.joints, before.gripper_cm, after.gripper_cm);
    const out: Json = { move, now: after };
    if (this.moves.length > 0) out.previous_moves = this.moves.slice(-3);
    this.moves = [...this.moves, move].slice(-5);
    if (clipped.length > 0) out.clipped_to_limits = clipped;
    return { kind: "text", text: AgentTools.json(out), problem: clipped.length === 0 ? undefined : `Clamped to range: ${clipped.join(", ")}` };
  }

  /** La foto del modelo 3D en la misma pose: muestra la forma del brazo aunque las cámaras no lo vean entero. */
  private async twinPhoto(): Promise<Photo | null> {
    if (!this.twinLoaded) return null;
    try {
      return { label: "3D model (replica in the robot's current pose)", jpeg: await this.twin.capture(null) };
    } catch {
      return null;
    }
  }

  /** `signal`: la persona paró el chat; se cortan las órdenes del modelo y los movimientos del brazo. */
  async chatRun(name: string, input: Json, signal?: AbortSignal): Promise<ChatToolOutput> {
    if (!this.isReady) throw new Error("The robot is no longer live.");
    switch (name) {
      case "get_state": {
        const out = await this.pose();
        if (this.moves.length > 0) out.previous_moves = this.moves.slice(-3);
        return { kind: "text", text: AgentTools.json(out) };
      }

      case "move_joints": {
        const batch: Record<string, number> = {};
        for (const t of (input.targets as Json[]) ?? []) {
          const v = num(t.value);
          if (typeof t.joint === "string" && v != null) batch[t.joint] = v;
        }
        const [clamped, clipped] = this.clamp(batch);
        return this.perform(clamped, clipped);
      }

      case "go_to_pose": {
        const pose = this.knowledge.active?.poses.find((p) => p.name === input.name);
        if (!pose) return { kind: "text", text: "There's no pose with that name.", problem: "Unknown pose" };
        const target = { ...pose.joints };
        for (const [j, d] of Object.entries(UseLiveRobot.offsets(input))) target[j] = (target[j] ?? 0) + d;
        const [clamped, clipped] = this.clamp(target);
        return this.perform(clamped, clipped);
      }

      case "play_segment": {
        const active = this.knowledge.active;
        const s = active?.segments.find((x) => x.name === input.name);
        const traj = s ? active?.trajectories[String(s.episode)] : undefined;
        if (!active || !s || !traj) return { kind: "text", text: "There's no segment with that name.", problem: "Unknown segment" };
        const offsets = UseLiveRobot.offsets(input), speed = UseLiveRobot.speed(input);
        // Las columnas de la trayectoria siguen el orden del dataset; el robot espera el suyo.
        const order = jointOrder(active);
        const joints = this.joints;
        const points = traj
          .filter((row) => row[0] >= s.from - 0.01 && row[0] <= s.to + 0.01)
          .map((row) => [
            row[0],
            ...RealAgentTools.joints.map((j) => {
              const i = order.indexOf(j);
              return (i >= 0 ? row[i + 1] : joints[j] ?? 0) + (offsets[j] ?? 0);
            }),
          ]);
        const last = points[points.length - 1];
        if (!last) return { kind: "text", text: "The segment is empty.", problem: "Empty segment" };
        const end = Object.fromEntries(RealAgentTools.joints.map((j, i) => [j, last[i + 1]]));
        return this.perform(this.clamp(end)[0], [], async () => {
          await this.lerobot.liveTrajectory(points, speed);
          return (s.to - s.from) / speed + 2;
        });
      }

      case "look_references":
        return { kind: "images", images: (this.knowledge.active?.pictures ?? []).map((p) => ({ label: p.label, jpeg: p.jpeg })) };

      case "run_skill": {
        if (this.skillModel == null) return { kind: "text", text: "No action model is loaded.", problem: "No model" };
        const instruction = typeof input.instruction === "string" ? input.instruction : "";
        const onAbort = () => this.stopSkill();
        signal?.addEventListener("abort", onAbort);
        let ended: SkillResult | null;
        try {
          ended = await this.runSkill(instruction, RealAgentTools.clampSkillSeconds(input), signal);
        } finally {
          signal?.removeEventListener("abort", onAbort);
        }
        const out = await this.pose();
        out.result = ended ? { reason: ended.reason, seconds: ended.seconds } : { reason: "unknown" };
        const photos = (await this.lerobot.liveLook().catch(() => [])).map((p) => ({ label: this.label(p.camera), jpeg: p.jpeg }));
        const failed = ended?.reason.startsWith("error") === true;
        return { kind: "report", text: AgentTools.json(out), photos, problem: failed ? ended?.reason : undefined };
      }

      case "pick":
      case "place":
      case "gripper": {
        const spec: Json = { type: name };
        if (name === "gripper") {
          spec.open = input.open ?? true;
        } else {
          const camera = typeof input.camera === "string" ? input.camera : "";
          const x = num(input.x) ?? 0, y = num(input.y) ?? 0;
          const height = (num(input.height_cm) ?? 2.5) / 100;
          const surface = (num(input.surface_cm) ?? 0) / 100;
          // Al agarrar se señala la cara de arriba del objeto; al dejar, la superficie donde va.
          const r = this.tablePoint(camera, x, y, name === "pick" ? height : surface);
          if (!r.ok) return { kind: "text", text: armProblemMessage(r.problem), problem: "Can't locate it" };
          spec.point = r.point;
          spec.height = height;
          spec.surface = surface;
        }
        // Al parar el chat, el robot se queda donde está (objetivos vacíos cortan la trayectoria).
        const onAbort = () => void this.lerobot.liveTargets({}).catch(() => {});
        signal?.addEventListener("abort", onAbort);
        let outcome: Json;
        try {
          outcome = await this.runArmSkill(spec, this.chatTitle(name, input) + "…");
        } finally {
          signal?.removeEventListener("abort", onAbort);
        }
        const photos = await this.lerobot.liveLook();
        const images = await Promise.all(photos.map((p) => this.gridded(this.label(p.camera), p.jpeg)));
        const model = await this.twinPhoto();
        if (model) images.push(model);
        const failed = outcome.done !== true;
        return { kind: "report", text: AgentTools.json(outcome), photos: images, problem: failed && typeof outcome.message === "string" ? outcome.message : undefined };
      }

      case "look": {
        const photos = await this.lerobot.liveLook();
        const images = await Promise.all(photos.map((p) => this.gridded(this.label(p.camera), p.jpeg)));
        const model = await this.twinPhoto();
        if (model) images.push(model);
        return { kind: "images", images };
      }

      case "go_home":
        await this.lerobot.liveHome();
        await this.settle(8);
        return { kind: "text", text: AgentTools.json(await this.pose()) };

      default:
        return { kind: "text", text: `Unknown tool: ${name}`, problem: "Unknown tool" };
    }
  }
}
