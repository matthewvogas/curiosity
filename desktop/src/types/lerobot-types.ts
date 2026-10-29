import type { SwiftDate } from "@/utils/codable";

/** Lo que se sabe del LeRobot instalado (lo dice el puente al arrancar). */
export type LeRobotEnv = { version: string; hubUser?: string | null; smolvla: boolean };

/** Calibraciones guardadas por LeRobot: carpeta (so_follower, koch_leader…) → nombres (mi_follower…). */
export type Calibrations = { robots: Record<string, string[]>; teleoperators: Record<string, string[]> };

/** Un tipo de robot o de teleoperador que trae LeRobot (--robot.type / --teleop.type). */
export type RobotKind = {
  type: string;
  /** Si se conecta por un puerto serie. */
  port: boolean;
  /** La carpeta donde LeRobot guarda sus calibraciones (null si no se pudo saber sin conectarlo). */
  calibration?: string | null;
};

export type CameraInfo = {
  index: number;
  name: string;
  /** Enchufada por USB (no la integrada ni la del teléfono): la preferida para el robot. */
  external: boolean;
};

/** Un dataset de LeRobot en esta computadora (grabado aquí o descargado del Hub). */
export type DatasetInfo = {
  /** Carpeta, o <usuario>/<nombre> si vino del Hub. */
  name: string;
  root: string;
  source: "local" | "hub" | string;
  episodes: number;
  frames: number;
  fps?: number | null;
  tasks: string[];
  bytes: number;
  cameras: string[];
};
export const datasetRepoID = (d: DatasetInfo) => (d.source === "hub" ? d.name : `local/${d.name}`);

/** Un dataset del Hub de Hugging Face (resultado de búsqueda). */
export type HubDataset = { id: string; downloads: number; likes: number };

/** El estado de lo que corre con el robot: teleoperar, grabar o un modelo. */
export type RobotSession = {
  /** teleop · record · rollout · live · simrecord */
  kind: string;
  /** starting · running · recording · reset · saving · returning · stopping · done · error */
  phase: string;
  active: boolean;
  error?: string | null;
  hz: number;
  joints: Record<string, number>;
  /** Las articulaciones del robot, en orden, y su unidad («deg», «0-100», «±100»), como las da LeRobot. */
  jointNames: string[];
  units: Record<string, string>;
  episode: number;
  target: number;
  elapsed: number;
  limit: number;
  /** En vivo: a dónde va cada articulación y su rango (grados; la pinza de 0 a 100). */
  targets: Record<string, number>;
  limits: Record<string, [number, number]>;
  /** En vivo: reproduciendo un tramo de una demostración. */
  playing: boolean;
  /** Al probar un modelo: sus cámaras, con el nombre que espera (p. ej. up, side), en orden. */
  cameras: string[];
  /** En vivo: el modelo de órdenes cargado, la orden que está haciendo y cómo terminó la última. */
  skillModel?: SkillModel | null;
  skill?: SkillRun | null;
  skillLast?: SkillResult | null;
};

export const sessionRemaining = (s: RobotSession) => Math.max(0, s.limit - s.elapsed);

/** Un modelo que entiende órdenes en palabras (SmolVLA, π0…), cargado en la sesión en vivo. */
export type SkillModel = { path: string; type: string; device: string; note?: string | null };
export type SkillRun = { instruction: string; elapsed: number; limit: number };
/** reason: time · stopped · interrupted · error: … */
export type SkillResult = { instruction: string; reason: string; seconds: number };

/** Una pieza revisada antes de grabar o probar: follower, leader, poses, cámara o permiso. */
export type PreflightCheck = {
  key: string;
  state: "ok" | "warn" | "fail";
  detail: string;
  /** El nombre a mostrar cuando dice más que la clave (p. ej. «up · OsmoPocket3»). */
  label?: string | null;
};

export function preflightTitle(c: PreflightCheck): string {
  if (c.label) return c.label;
  const fixed: Record<string, string> = { follower: "Follower", leader: "Leader", pose: "Poses", cameras: "Cameras", camera: "Camera", permission: "Camera permission" };
  if (fixed[c.key]) return fixed[c.key];
  if (c.key.startsWith("cam")) {
    const n = Number(c.key.slice(3));
    return `Camera ${Number.isFinite(n) ? n + 1 : 2}`;
  }
  return c.key;
}

/** Un entrenamiento lanzado desde la app (corre aparte aunque se cierre la app). */
export type TrainJob = {
  name: string;
  /** repo_id (local/… o usuario/…) */
  dataset: string;
  /** Solo para los locales. */
  datasetRoot?: string | null;
  policy: string;
  steps: number;
  batchSize: number;
  started: SwiftDate;
  pid: number;
  log: string;
  outputDir: string;
  stopped?: SwiftDate | null;
};

/** El avance de un entrenamiento, leído de su registro. */
export type TrainProgress = {
  step: number;
  total?: number;
  elapsed?: string;
  remaining?: string;
  loss?: number;
  finished: boolean;
  error?: string;
  running: boolean;
  hasModel: boolean;
};
export const progressFraction = (p: TrainProgress) => (p.total && p.total > 0 ? p.step / p.total : 0);

/** Un punto de la curva de pérdida de un entrenamiento. */
export type LossPoint = { step: number; loss: number };

/** Lo que se ve de un entrenamiento abierto en vivo: su curva y las últimas líneas del registro. */
export type TrainWatch = { name: string; history: LossPoint[]; log: string[] };

/** Modelos de LeRobot que se pueden entrenar desde la app. */
export type PolicyOption = { id: string; name: string; basePath: string | null; needsSmolVLA: boolean };

export const POLICIES: PolicyOption[] = [
  { id: "act", name: "ACT", basePath: null, needsSmolVLA: false },
  { id: "diffusion", name: "Diffusion", basePath: null, needsSmolVLA: false },
  { id: "smolvla", name: "SmolVLA", basePath: "lerobot/smolvla_base", needsSmolVLA: true },
];
