import { makeAutoObservable, observable } from "mobx";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { SimulationQueries } from "@/queries/simulation-queries";
import { RobotQueries } from "@/queries/robot-queries";
import { Preferences } from "@/queries/preferences";
import {
  actuatedJoints, defaultPhysics, defaultRender, emptySimulationState,
  type JointInfo, type Keyframe, type PhysicsSettings, type RenderOptions, type Robot, type RobotModel,
  type SceneObject, type SimulationState,
} from "@/types/robot-types";
import type { ChatBody, ChatToolOutput } from "@/types/chat-types";
import type { ObjectPart } from "@/types/robot-types";
import type { UseSettings } from "./use-settings";
import { AnthropicQueries } from "@/queries/anthropic-queries";
import { ObjectDesigner } from "@/utils/object-designer";
import { swiftDate, uuid } from "@/utils/codable";
import { Units } from "@/utils/units";
import { SimulationChat } from "./simulation-chat";
import { RobotNotes } from "@/utils/robot-notes";

type Json = Record<string, any>;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * La simulación del robot abierto: carga, estado en vivo y órdenes (de la persona o de la IA).
 * También es el cuerpo del chat del simulador (ChatBody): las herramientas están en simulation-chat.ts.
 */
export class UseSimulation implements ChatBody {
  readonly engine = new SimulationQueries();

  engineReady = false;
  loadingText: string | null = null;
  error: string | null = null;
  model: RobotModel | null = null;
  state: SimulationState = emptySimulationState();
  objects: SceneObject[] = [];
  speed = 1;
  activeCamera: string | null = null;
  /** El objeto seleccionado (con un clic en la escena o en la lista), o ninguno. */
  selectedObject: number | null = null;
  physics: PhysicsSettings = defaultPhysics();
  render: RenderOptions = defaultRender();
  keyframes: Keyframe[] = [];
  /** Aviso corto tras una acción (captura guardada, estado copiado…). */
  notice: string | null = null;
  /** Lo que la IA está diseñando ahora («Kitchen knife»…) y el error del último intento. */
  designing: string | null = null;
  designError: string | null = null;

  /**
   * Vistas fijas alrededor de la escena (lados y esquinas), para mirar y para que la IA vea lo que la cámara
   * de arriba no ve. Se eligen en el menú de vista y se recuerdan entre robots.
   */
  static readonly viewAngles: { name: string; azimuth: number }[] = [
    { name: "Front", azimuth: 0 }, { name: "Front-left", azimuth: 45 }, { name: "Left", azimuth: 90 }, { name: "Back-left", azimuth: 135 },
    { name: "Back", azimuth: 180 }, { name: "Back-right", azimuth: -135 }, { name: "Right", azimuth: -90 }, { name: "Front-right", azimuth: -45 },
  ];
  views: string[] = Preferences.get<string[]>("sim.views", []);

  private loadedRobotID: string | null = null;
  private current: { robot: Robot; profile: Json } | null = null;
  private rootLink: string | null = null;
  private modelCameras: string[] = [];
  private placedViews: string[] = [];
  private noticeTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(private settings: UseSettings) {
    makeAutoObservable<UseSimulation, "current" | "noticeTimer" | "settings">(this, {
      engine: false,
      settings: false,
      current: observable.ref,
      model: observable.ref,
      state: observable.ref,
      objects: observable.ref,
      keyframes: observable.ref,
      physics: observable.ref,
      render: observable.ref,
      noticeTimer: false,
    });
    this.engine.onMessage = (message) => this.handle(message);
    // Un visor nuevo empieza vacío: se le vuelve a cargar el robot abierto (fuera de la actualización de la vista).
    // Si la pantalla lo abre enseguida (al montarse), no hace falta cargarlo dos veces.
    this.engine.onAttach = () => {
      this.loadedRobotID = null;
      queueMicrotask(() => {
        if (this.loadedRobotID === null) this.reload();
      });
    };
  }

  open(robot: Robot, profile: Json, force = false) {
    if (!force && this.loadedRobotID === robot.id) return;
    this.loadedRobotID = robot.id;
    this.current = { robot, profile };
    this.keyframes = [];
    RobotQueries.keyframes(robot.id).then((k) => {
      if (this.current?.robot.id === robot.id) this.keyframes = k;
    });
    this.model = null;
    this.error = null;
    this.objects = [];
    this.activeCamera = null;
    this.loadingText = `Opening ${robot.name}…`;
    this.engine.load(SimulationQueries.modelURL(robot), profile);
  }

  // ---------- Controles ----------

  togglePause() {
    this.engine.pause(!this.state.paused);
    this.state = { ...this.state, paused: !this.state.paused };
  }
  /** Vuelve a leer el URDF y su perfil desde el disco (para ver cambios hechos fuera). */
  reload() {
    const c = this.current;
    if (c) this.open(c.robot, c.profile, true);
  }
  align() {
    this.engine.view("tres");
  }

  /** Todas las articulaciones al objetivo cero (el «Clear all» de MuJoCo). */
  clearControls() {
    for (const j of this.model ? actuatedJoints(this.model) : []) {
      const zero = j.lower != null ? Math.min(j.upper ?? 0, Math.max(j.lower, 0)) : 0;
      this.setTarget(j.name, zero);
    }
  }

  setPhysics(p: PhysicsSettings) {
    this.physics = p;
    this.engine.setPhysics(p);
  }
  setRender(r: RenderOptions) {
    this.render = r;
    this.engine.setRender(r);
  }
  setViews(views: string[]) {
    this.views = views;
    Preferences.set("sim.views", views);
    void this.placeViews();
  }

  // ---------- Keyframes, copiar estado, captura ----------

  async saveKeyframe() {
    const robot = this.current?.robot;
    if (!robot) return;
    let json: string;
    try {
      json = await this.engine.keyframe();
    } catch {
      return;
    }
    this.keyframes = [...this.keyframes, { id: uuid(), name: `Pose ${this.keyframes.length + 1}`, json, savedAt: swiftDate.now() }];
    this.persistKeyframes(robot);
    this.flash("Pose saved");
  }

  loadKeyframe(key: Keyframe) {
    this.engine.setKeyframe(key.json);
  }

  deleteKeyframe(key: Keyframe) {
    const robot = this.current?.robot;
    if (!robot) return;
    this.keyframes = this.keyframes.filter((k) => k.id !== key.id);
    this.persistKeyframes(robot);
  }

  async copyState() {
    try {
      const json = await this.engine.keyframe();
      await navigator.clipboard.writeText(json);
      this.flash("State copied");
    } catch {
      /* sin motor listo: nada que copiar */
    }
  }

  async screenshot() {
    const robot = this.current?.robot;
    if (!robot) return;
    try {
      const png = await this.engine.capture(null, { width: 2400, png: true });
      const path = await RobotQueries.saveScreenshot(png, robot.name);
      void revealItemInDir(path).catch(() => {});
      this.flash("Screenshot saved to Pictures");
    } catch (e) {
      this.flash(e instanceof Error ? e.message : String(e));
    }
  }

  /** Resumen del modelo en texto («Print model» de MuJoCo). */
  get modelSummary(): string {
    const m = this.model;
    if (!m) return "";
    const lines = [`Model: ${m.name}`, `Links: ${m.links.length} · Moving joints: ${m.joints.length} · Mass: ${m.mass.toFixed(3)} kg`, ""];
    lines.push("Links");
    lines.push(...m.links.map((l) => `  ${l}`));
    lines.push("");
    lines.push("Joints (type · range · kp · kd · max force)");
    for (const j of m.joints) {
      const range = j.lower != null && j.upper != null ? `${Units.format(j.lower, j.type)} … ${Units.format(j.upper, j.type)}` : "unlimited";
      lines.push(`  ${j.name} · ${j.type} · ${range} · ${j.kp.toFixed(1)} · ${j.kd.toFixed(2)} · ${j.fmax.toFixed(1)}`);
    }
    if (m.cameras.length) lines.push("", "Cameras: " + m.cameras.join(", "));
    if (m.warnings.length) lines.push("", "Warnings", ...m.warnings.map((w) => `  ${w}`));
    return lines.join("\n");
  }

  private persistKeyframes(robot: Robot) {
    RobotQueries.saveKeyframes(this.keyframes, robot.id).catch(() => {});
  }

  private flash(text: string) {
    this.notice = text;
    if (this.noticeTimer) clearTimeout(this.noticeTimer);
    this.noticeTimer = setTimeout(() => {
      if (this.notice === text) this.notice = null;
    }, 2500);
  }

  step() {
    this.engine.step(10);
  }
  reset() {
    this.engine.reset();
  }
  setSpeed(x: number) {
    this.speed = x;
    this.engine.setSpeed(x);
  }
  view(name: string) {
    this.engine.view(name);
  }

  showCamera(name: string | null) {
    this.activeCamera = name;
    this.engine.showCamera(name);
  }

  /** Selecciona un objeto (o ninguno): la escena lo marca con su contorno y la lista lo abre. */
  selectObject(id: number | null) {
    this.selectedObject = id;
    this.engine.select(id);
  }

  /** Objetivo de una articulación en unidades del motor (rad o m). */
  setTarget(joint: string, value: number) {
    this.engine.setTarget(joint, value);
    if (this.state.joints.some((j) => j.name === joint)) {
      this.state = { ...this.state, joints: this.state.joints.map((j) => (j.name === joint ? { ...j, target: value } : j)) };
    }
    if (this.state.paused) this.togglePause(); // mover un control es pedirle que corra
  }

  setGains(joint: string, gains: { kp?: number; kd?: number; fmax?: number }) {
    this.engine.setGains(joint, gains);
    const m = this.model;
    if (!m || !m.joints.some((j) => j.name === joint)) return;
    const clean = Object.fromEntries(Object.entries(gains).filter(([, v]) => v != null));
    this.model = { ...m, joints: m.joints.map((j) => (j.name === joint ? { ...j, ...clean } : j)) };
  }

  async addObject(object: SceneObject): Promise<number> {
    const id = await this.engine.addObject({
      shape: object.shape, size: object.size, mass: object.mass, color: object.color,
      pos: object.drop ? undefined : object.pos, yaw: object.yaw, euler: object.euler ?? undefined,
      parts: object.parts ?? undefined, drop: object.drop, fixed: object.fixed, name: object.name,
    });
    this.objects = [...this.objects, { ...object, id }];
    return id;
  }

  /**
   * Un objeto nuevo a partir de una descripción («una rueda», «un escritorio», «un cuchillo»): la IA lo arma
   * con piezas simples en tamaño y peso reales, y se suelta en un lugar libre de la mesa. Devuelve su id.
   */
  async designObject(description: string): Promise<{ id: number; object: SceneObject }> {
    const text = description.trim();
    const key = this.settings.anthropicKey;
    if (!text) throw new Error("Describe the object first.");
    if (!key) throw new Error("Add your Claude API key in Settings to create objects with AI.");
    this.designing = text;
    this.designError = null;
    try {
      const response = await AnthropicQueries.createMessage(key, ObjectDesigner.request(text, this.settings.modelID));
      const object = ObjectDesigner.parse(response);
      const id = await this.addObject(object);
      this.flash(`Added ${object.name}`);
      return { id, object };
    } catch (e) {
      this.designError = e instanceof Error ? e.message : String(e);
      throw e;
    } finally {
      this.designing = null;
    }
  }

  /**
   * Cambia un objeto de la escena: moverlo o girarlo (queda quieto ahí y la física sigue), o su peso, color,
   * nombre y si está fijo.
   */
  async updateObject(id: number, changes: Partial<Pick<SceneObject, "pos" | "yaw" | "mass" | "color" | "name" | "fixed">>) {
    if (!(await this.engine.updateObject(id, changes))) return;
    this.objects = this.objects.map((o) =>
      o.id !== id ? o : { ...o, ...changes, parts: changes.color && o.parts ? o.parts.map((p) => ({ ...p, color: changes.color! })) : o.parts },
    );
  }

  /** El giro actual de cada objeto (grados alrededor de z), para mostrarlo al abrir su detalle. */
  async objectYaws(): Promise<Record<number, number>> {
    try {
      return Object.fromEntries((await this.engine.objectPoses()).map((p) => [p.id, p.yaw]));
    } catch {
      return {};
    }
  }

  removeObject(id: number) {
    if (this.selectedObject === id) this.selectedObject = null;
    this.engine.removeObject(id);
    this.objects = this.objects.filter((o) => o.id !== id);
  }

  capture(camera: string | null, grid = false): Promise<string> {
    return this.engine.capture(camera, { grid });
  }
  cameraSize(camera: string): Promise<{ width: number; height: number }> {
    return this.engine.cameraSize(camera);
  }

  /** Una habilidad del ejecutor (agarrar, dejar, abrir la pinza…): corre sola y devuelve cómo salió. */
  async skill(spec: Json, signal?: AbortSignal): Promise<Json> {
    if (this.state.paused) this.togglePause();
    // Como el withTaskCancellationHandler de Swift: si se cancela, el motor suelta la habilidad.
    const cancel = () => this.engine.cancelSkill();
    signal?.addEventListener("abort", cancel, { once: true });
    try {
      return await this.engine.skill(spec);
    } finally {
      signal?.removeEventListener("abort", cancel);
    }
  }

  /** Deja correr la simulación `seconds` segundos de tiempo simulado (o hasta 3× eso de reloj). */
  async run(seconds: number, signal?: AbortSignal) {
    if (this.state.paused) this.togglePause();
    const start = this.state.time;
    const deadline = Date.now() + (seconds * 3 + 0.5) * 1000;
    while (this.state.time - start < seconds && Date.now() < deadline && !signal?.aborted) {
      await sleep(100);
    }
  }

  // ---------- Vistas alrededor de la escena ----------

  /**
   * Pone las vistas elegidas alrededor de lo que hay en escena (las piezas del robot y los objetos), a una
   * distancia que lo deja entero en la imagen. Van en la base del robot: son cámaras fijas, como «Overhead».
   */
  async placeViews() {
    const root = this.rootLink;
    if (!this.model || !root) return;
    for (const name of this.placedViews) this.engine.removeCamera(name);
    this.placedViews = [];
    if (this.views.length) {
      let links: Record<string, number[]> | null = null;
      try {
        links = await this.engine.linkPositions();
      } catch {
        links = null;
      }
      if (links) {
        const points = [...Object.values(links), ...Object.values(this.state.objectPositions).filter(Boolean)];
        const lo = [0, 1, 2].map((i) => (points.length ? Math.min(...points.map((p) => p[i])) : 0));
        const hi = [0, 1, 2].map((i) => (points.length ? Math.max(...points.map((p) => p[i])) : 0));
        const center = [0, 1, 2].map((i) => (lo[i] + hi[i]) / 2);
        const radius = Math.max(0.15, Math.sqrt([0, 1, 2].map((i) => ((hi[i] - lo[i]) / 2) ** 2).reduce((a, b) => a + b, 0)));
        const fovy = 55;
        const elevation = (35 * Math.PI) / 180;
        const distance = (radius / Math.tan(((fovy / 2) * Math.PI) / 180)) * 1.15;
        const placed: string[] = [];
        for (const { name, azimuth } of UseSimulation.viewAngles) {
          if (!this.views.includes(name)) continue;
          const a = (azimuth * Math.PI) / 180;
          const dir = [Math.cos(elevation) * Math.cos(a), Math.cos(elevation) * Math.sin(a), Math.sin(elevation)];
          const camera = `${name} view`;
          this.engine.addCamera({
            name: camera, link: root, pos: [0, 1, 2].map((i) => center[i] + dir[i] * distance),
            quat: lookQuat(dir), fovy, width: 640, height: 480,
          });
          placed.push(camera);
        }
        this.placedViews = placed;
      }
    }
    if (this.model) this.model = { ...this.model, cameras: [...this.modelCameras, ...this.placedViews] };
    if (this.activeCamera && !(this.model?.cameras.includes(this.activeCamera) ?? false)) this.showCamera(null);
  }

  // ---------- Mensajes del motor ----------

  private handle(m: Json) {
    switch (m.type) {
      case "ready":
        this.engineReady = true;
        break;
      case "loading":
        this.loadingText = typeof m.text === "string" ? m.text : null;
        break;
      case "error":
        this.loadingText = null;
        this.error = typeof m.text === "string" ? m.text : null;
        break;
      case "model": {
        this.loadingText = null;
        const model = parseModel(m);
        this.model = model;
        this.objects = model.objects;
        this.rootLink = typeof m.root === "string" ? m.root : null;
        this.modelCameras = model.cameras;
        this.placedViews = []; // al cargar, el motor empieza sin las vistas
        void this.placeViews();
        // Abre quieto: la física corre cuando la persona le da a reproducir (o cuando la IA lo mueve).
        this.engine.pause(true);
        this.state = { ...this.state, paused: true };
        this.engine.setRender(this.render);
        this.engine.setPhysics(this.physics);
        break;
      }
      case "select":
        // Un clic en la escena: la lista abre ese objeto (o se cierra, si fue en vacío).
        this.selectedObject = typeof m.id === "number" ? m.id : null;
        break;
      case "state": {
        const next = parseState(m);
        if (JSON.stringify(next) !== JSON.stringify(this.state)) this.state = next;
        break;
      }
    }
  }

  // ---------- El chat (ChatBody): ver simulation-chat.ts ----------

  get chatTools() {
    return SimulationChat.tools;
  }
  get chatNotReady() {
    return SimulationChat.notReady;
  }
  chatSystemPrompt(robotName: string): string | null {
    return SimulationChat.systemPrompt(this, robotName);
  }
  chatTitle(name: string, input: Json): string {
    return SimulationChat.title(name, input);
  }
  /** En la simulación no hay riesgo: nada espera aprobación. */
  chatApproval(_name: string, _input: Json): string | null {
    return null;
  }
  /** `signal` (opcional): la cancelación del chat, como la de una Task de Swift. */
  chatRun(name: string, input: Json, signal?: AbortSignal): Promise<ChatToolOutput> {
    return SimulationChat.run(this, name, input, signal);
  }
  /** Lo que el motor mide del robot cargado (brazo, pinza) y sus cámaras, para sus notas. */
  async chatRobotFacts(): Promise<string[] | null> {
    if (!this.model) return null;
    const [effector, cameras] = await Promise.all([
      this.engine.call<Json | null>("effector").catch(() => null),
      this.engine.call<Json[] | null>("cameraInfo", 768).catch(() => null),
    ]);
    const list = (cameras ?? []).map((c) => ({ name: String(c.name), fixed: !!c.fixed, link: typeof c.link === "string" ? c.link : undefined }));
    return RobotNotes.factsLines(effector, list);
  }
}

// ---------- Interno ----------

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const optNum = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const strings = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
const numbers = (v: unknown) => (Array.isArray(v) ? v.map(num) : null);

/**
 * La orientación de una cámara de MuJoCo (mira hacia −z, y arriba) cuyo −z apunta en contra de `back`
 * (unitario), con la vertical hacia arriba. Cuaternión [x, y, z, w].
 */
function lookQuat(z: number[]): number[] {
  const cross = (a: number[], b: number[]) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const unit = (v: number[]) => {
    const n = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
    return v.map((x) => x / n);
  };
  const x = unit(cross([0, 0, 1], z));
  const y = cross(z, x);
  // Matriz de rotación con columnas x, y, z → cuaternión.
  const [m00, m11, m22] = [x[0], y[1], z[2]];
  const trace = m00 + m11 + m22;
  if (trace > 0) {
    const s = Math.sqrt(trace + 1) * 2;
    return [(y[2] - z[1]) / s, (z[0] - x[2]) / s, (x[1] - y[0]) / s, s / 4];
  } else if (m00 > m11 && m00 > m22) {
    const s = Math.sqrt(1 + m00 - m11 - m22) * 2;
    return [s / 4, (y[0] + x[1]) / s, (z[0] + x[2]) / s, (y[2] - z[1]) / s];
  } else if (m11 > m22) {
    const s = Math.sqrt(1 + m11 - m00 - m22) * 2;
    return [(y[0] + x[1]) / s, s / 4, (z[1] + y[2]) / s, (z[0] - x[2]) / s];
  } else {
    const s = Math.sqrt(1 + m22 - m00 - m11) * 2;
    return [(z[0] + x[2]) / s, (z[1] + y[2]) / s, s / 4, (x[1] - y[0]) / s];
  }
}

function parseModel(m: Json): RobotModel {
  const joints: JointInfo[] = (Array.isArray(m.joints) ? m.joints : []).map((j: Json) => ({
    name: typeof j.name === "string" ? j.name : "",
    type: typeof j.type === "string" ? j.type : "revolute",
    lower: optNum(j.lower),
    upper: optNum(j.upper),
    effort: num(j.effort),
    kp: num(j.kp),
    kd: num(j.kd),
    fmax: num(j.fmax),
    actuated: typeof j.actuated === "boolean" ? j.actuated : true,
    mimic: typeof j.mimic === "string" ? j.mimic : null,
  }));
  return {
    name: typeof m.name === "string" ? m.name : "robot",
    links: strings(m.links),
    joints,
    cameras: strings(m.cameras),
    objects: (Array.isArray(m.objects) ? m.objects : []).map(parseObject),
    warnings: strings(m.warnings),
    mass: num(m.mass),
    floating: m.floating === true,
  };
}

function parseObject(o: Json): SceneObject {
  return {
    id: Math.trunc(num(o.id)),
    shape: typeof o.shape === "string" ? o.shape : "box",
    size: numbers(o.size) ?? [],
    mass: num(o.mass),
    color: typeof o.color === "string" ? o.color : "#cccccc",
    pos: numbers(o.pos) ?? [0, 0, 0],
    yaw: num(o.yaw),
    fixed: o.fixed === true,
    name: typeof o.name === "string" ? o.name : "",
    parts: Array.isArray(o.parts) ? (o.parts as ObjectPart[]) : null,
    euler: numbers(o.euler) ?? null,
  };
}

function parseState(m: Json): SimulationState {
  const s = emptySimulationState();
  s.time = num(m.t);
  s.realTimeFactor = num(m.rtf);
  s.paused = m.paused === true;
  s.contacts = Math.trunc(num(m.contacts));
  s.maxForce = num(m.maxForce);
  s.stepMs = num(m.stepMs);
  for (const l of Array.isArray(m.links) ? m.links : []) {
    if (typeof l?.name === "string") s.linkForces[l.name] = num(l.force);
  }
  s.joints = (Array.isArray(m.joints) ? m.joints : []).map((j: Json) => ({
    name: typeof j.name === "string" ? j.name : "",
    q: num(j.q),
    qd: num(j.qd),
    target: num(j.target),
    force: num(j.force),
  }));
  for (const o of Array.isArray(m.objects) ? m.objects : []) {
    const pos = numbers(o?.pos);
    if (typeof o?.id === "number" && pos) s.objectPositions[Math.trunc(o.id)] = pos;
  }
  return s;
}
