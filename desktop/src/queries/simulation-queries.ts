import { isWindows } from "./native";
import type { PhysicsSettings, RenderOptions, Robot } from "@/types/robot-types";

type Json = Record<string, any>;

/** Base de las URLs que sirve el backend (curiosity://): en Windows, WebView2 las pide por http. */
export function schemeBase(): string {
  return isWindows() ? "http://curiosity.localhost" : "curiosity://localhost";
}

/** Una ruta del disco como URL del esquema curiosity:// (/fs/…), con cada parte codificada. */
export function fileURL(path: string): string {
  const parts = path.replace(/\\/g, "/").split("/").filter(Boolean).map(encodeURIComponent);
  // C: no se codifica (queda «C:»).
  return `${schemeBase()}/fs/${parts.map((p) => p.replace("%3A", ":")).join("/")}`;
}

/**
 * Puente con el motor de simulación (resources/studio/engine.js, dentro de un iframe).
 * Manda órdenes a `window.studio.*` por postMessage (studio/rpc.js) y entrega crudos los mensajes que el
 * motor publica (ready, loading, model, state, log, error).
 */
export class SimulationQueries {
  private frame: HTMLIFrameElement | null = null;
  private pending: Array<[string, unknown[]]> = [];
  private ready = false;
  private nextRPC = 1;
  private calls = new Map<number, { resolve: (v: any) => void; reject: (e: Error) => void }>();

  /** Cada mensaje del motor, sin transformar. */
  onMessage: (msg: Json) => void = () => {};
  /** Se montó un visor nuevo (al volver al simulador): hay que cargarle el robot otra vez. */
  onAttach: () => void = () => {};

  static engineURL(): string {
    return `${schemeBase()}/app/studio/index.html`;
  }

  static modelURL(robot: Robot): string {
    return robot.source === "bundled" ? `${schemeBase()}/app/${robot.urdfPath}` : fileURL(robot.urdfPath);
  }

  constructor() {
    window.addEventListener("message", (e) => {
      if (!this.frame || e.source !== this.frame.contentWindow) return;
      const data = e.data || {};
      if (data.studio) {
        const msg = data.studio as Json;
        if (msg.type === "ready") {
          this.ready = true;
          for (const [fn, args] of this.pending) this.post(fn, args);
          this.pending = [];
        }
        this.onMessage(msg);
      } else if (typeof data.rpc === "number") {
        const call = this.calls.get(data.rpc);
        if (!call) return;
        this.calls.delete(data.rpc);
        if (data.ok) call.resolve(data.value);
        else call.reject(new Error(data.error));
      }
    });
  }

  attach(frame: HTMLIFrameElement) {
    if (this.frame === frame) return;
    this.frame = frame;
    this.ready = false;
    this.pending = []; // eran para el visor anterior
    for (const c of this.calls.values()) c.reject(new Error("The simulation closed."));
    this.calls.clear();
    this.onAttach();
  }

  detach(frame: HTMLIFrameElement) {
    if (this.frame === frame) {
      this.frame = null;
      this.ready = false;
    }
  }

  get isReady() {
    return this.ready;
  }

  // ---------- Órdenes al motor ----------

  load(url: string, profile: Json) {
    this.send("load", { url, profile });
  }
  setTarget(joint: string, value: number) {
    this.send("setTarget", joint, value);
  }
  setTargets(q: Record<string, number>, snap = false) {
    this.send("setTargets", q, snap);
  }
  setGains(joint: string, gains: { kp?: number; kd?: number; fmax?: number }) {
    this.send("setGains", joint, gains);
  }
  setPhysics(p: PhysicsSettings) {
    this.send("setPhysics", { ...p, iterations: Math.round(p.iterations) });
  }
  setRender(r: RenderOptions) {
    this.send("setRender", r);
  }
  setKeyframe(json: string) {
    if (this.ready) this.send("setKeyframe", JSON.parse(json));
  }
  /** Estado completo en JSON (keyframe / copiar estado). */
  async keyframe(): Promise<string> {
    return JSON.stringify(await this.call("getKeyframe"));
  }
  /** Posición de cada pieza en metros, en el marco de la base del robot. */
  linkPositions(): Promise<Record<string, number[]>> {
    return this.call("linkPositions");
  }
  pause(on: boolean) {
    this.send("pause", on);
  }
  step(n = 1) {
    this.send("step", n);
  }
  reset() {
    this.send("reset", true);
  }
  setSpeed(x: number) {
    this.send("setSpeed", x);
  }
  view(name: string) {
    this.send("view", name);
  }
  showCamera(name: string | null) {
    this.send("showCamera", name);
  }
  select(id: number | null) {
    this.send("select", id);
  }
  /** Una cámara en una pieza: {name, link, pos, quat [x,y,z,w], fovy, width, height} (convención de MuJoCo). */
  addCamera(spec: Json) {
    this.send("addCamera", spec);
  }
  removeCamera(name: string) {
    this.send("removeCamera", name);
  }
  /** Cambia un objeto ya puesto: pos (m), yaw o euler (grados), mass, color, name, fixed. */
  async updateObject(id: number, changes: Json): Promise<boolean> {
    return (await this.call("updateObject", id, changes)) === true;
  }
  /** Dónde está y cómo está girado cada objeto ahora (m, grados alrededor de z). */
  objectPoses(): Promise<{ id: number; pos: number[]; yaw: number }[]> {
    return this.call("objectPoses");
  }
  removeObject(id: number) {
    this.send("removeObject", id);
  }
  async addObject(spec: Json): Promise<number> {
    return Number(await this.call("addObject", spec)) || 0;
  }
  /** px que tapa un panel a la derecha (para encuadrar el robot en lo que se ve). */
  setInset(right: number) {
    this.send("setInsets", { right: Math.round(right) });
  }

  /**
   * Imagen de la vista principal o de una cámara montada, en base64 (JPEG para la IA, PNG para capturas).
   * Con `grid`, la imagen lleva una cuadrícula con sus coordenadas en píxeles (para señalar).
   */
  async capture(camera: string | null, { width = 768, png = false, grid = false } = {}): Promise<string> {
    const url: string = await this.call("capture", camera, width, png ? "png" : "jpeg", grid);
    const comma = url?.indexOf(",") ?? -1;
    if (comma < 0) throw new Error("Couldn't capture the image.");
    return url.slice(comma + 1);
  }

  /** Una habilidad que se mueve sola (agarrar, dejar…) y cómo salió, cuando termina. */
  skill(spec: Json): Promise<Json> {
    return this.call("skill", spec);
  }
  cancelSkill() {
    this.send("cancelSkill");
  }
  /** Planifica una habilidad sin mover nada: la trayectoria (filas [t, radianes de `names`…]) y cómo salió. */
  planSkill(spec: Json, names: string[], speed: number): Promise<Json> {
    return this.call("planSkill", spec, { names, speed });
  }
  /** El centro del agarre ahora (m, marco de la base). */
  tip(): Promise<number[] | null> {
    return this.call("tip");
  }
  /** Límites de las articulaciones (radianes), p. ej. los de la calibración del robot real. */
  setLimits(limits: Record<string, number[]>) {
    this.send("setLimits", limits);
  }
  /** Tamaño en píxeles de la imagen de una cámara a `width` de ancho. */
  async cameraSize(camera: string, width = 768): Promise<{ width: number; height: number }> {
    const list: Json[] = (await this.call("cameraInfo", width)) ?? [];
    const c = list.find((x) => x.name === camera);
    return { width, height: c?.height ?? Math.round((width * 3) / 4) };
  }

  /** Cualquier otra función de window.studio (para lo que el motor agregue después). */
  call<T = any>(fn: string, ...args: unknown[]): Promise<T> {
    if (!this.frame?.contentWindow || !this.ready) return Promise.reject(new Error("The simulation isn't ready yet."));
    const rpc = this.nextRPC++;
    return new Promise<T>((resolve, reject) => {
      this.calls.set(rpc, { resolve, reject });
      this.frame!.contentWindow!.postMessage({ rpc, fn, args }, "*");
    });
  }

  // ---------- Interno ----------

  /** Sin esperar respuesta; si el motor aún no está listo, queda en fila. */
  send(fn: string, ...args: unknown[]) {
    if (this.ready) this.post(fn, args);
    else this.pending.push([fn, args]);
  }

  private post(fn: string, args: unknown[]) {
    this.frame?.contentWindow?.postMessage({ rpc: 0, fn, args }, "*");
  }
}
