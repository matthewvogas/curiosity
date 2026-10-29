import type { SwiftDate } from "@/utils/codable";

/** Un robot de la biblioteca: de dónde sale su modelo y su perfil. */
export type Robot = {
  id: string;
  name: string;
  summary: string;
  source: "bundled" | "file" | "library";
  /** Ruta del modelo (URDF o MJCF): relativa a los recursos (incluidos) o absoluta (importados y de la biblioteca). */
  urdfPath: string;
  license?: string;
  addedAt: SwiftDate;
};

/** Lo que el motor armó a partir del URDF. */
export type RobotModel = {
  name: string;
  links: string[];
  joints: JointInfo[];
  cameras: string[];
  objects: SceneObject[];
  warnings: string[];
  mass: number;
  /** La base no está fija al suelo (robots móviles, cuadrúpedos, humanoides). */
  floating: boolean;
};

/** Las articulaciones que se controlan (las acopladas y las pasivas se mueven solas). */
export const actuatedJoints = (m: RobotModel) => m.joints.filter((j) => j.actuated);

export type JointInfo = {
  name: string;
  type: string;
  lower?: number | null;
  upper?: number | null;
  effort: number;
  kp: number;
  kd: number;
  fmax: number;
  /** Tiene motor propio. */
  actuated: boolean;
  /** Sigue a otra articulación (pinzas de dos dedos, dedos acoplados). */
  mimic?: string | null;
};

/** Estado de una articulación en un instante (unidades SI: rad o m, N·m o N). */
export type JointState = { name: string; q: number; qd: number; target: number; force: number };

export type SimulationState = {
  time: number;
  realTimeFactor: number;
  paused: boolean;
  joints: JointState[];
  contacts: number;
  maxForce: number;
  objectPositions: Record<number, number[]>;
  /** Fuerza de contacto por pieza del robot (N). */
  linkForces: Record<string, number>;
  /** Profiler: milisegundos por paso de física. */
  stepMs: number;
};

export const emptySimulationState = (): SimulationState => ({
  time: 0, realTimeFactor: 0, paused: false, joints: [], contacts: 0, maxForce: 0, objectPositions: {}, linkForces: {}, stepMs: 0,
});

/**
 * Una pieza de un objeto compuesto (metros, grados). Cilindros y cápsulas con el eje en z; `pos` respecto
 * del centro del objeto.
 */
export type ObjectPart = { shape: "box" | "sphere" | "cylinder" | "capsule"; size: number[]; pos: number[]; euler: number[]; color: string };

/** Un objeto libre de la escena (metros, kg). */
export type SceneObject = {
  id: number;
  shape: "box" | "sphere" | "cylinder" | string;
  /** caja: [x, y, z] · esfera: [r] · cilindro: [r, alto] */
  size: number[];
  mass: number;
  color: string;
  pos: number[];
  yaw: number;
  fixed: boolean;
  name: string;
  /** Si está, el objeto se arma con estas piezas (una rueda, un escritorio…) en lugar de `shape`/`size`. */
  parts?: ObjectPart[] | null;
  /** Giro completo en grados [x, y, z]; si no está, solo `yaw`. */
  euler?: number[] | null;
  /** Que el motor elija un lugar libre y lo suelte desde un poco más arriba (ignora `pos`). */
  drop?: boolean;
};

export type PhysicsSettings = {
  gravity: number;
  friction: number;
  restitution: number;
  selfCollision: boolean;
  /** Paso de tiempo (s) e iteraciones del solver. */
  timestep: number;
  iterations: number;
  /** Ruido en el control, como MuJoCo: escala (fracción del rango) y tiempo de correlación (s). */
  noiseScale: number;
  noiseRate: number;
};

export const defaultPhysics = (): PhysicsSettings => ({
  gravity: 9.81, friction: 0.7, restitution: 0.05, selfCollision: false, timestep: 1 / 500, iterations: 8, noiseScale: 0, noiseRate: 0,
});

/** Qué se dibuja en la escena (flags de render de MuJoCo). */
export type RenderOptions = {
  contacts: boolean;
  joints: boolean;
  collision: boolean;
  com: boolean;
  transparent: boolean;
  grid: boolean;
  shadows: boolean;
};

export const defaultRender = (): RenderOptions => ({
  contacts: true, joints: false, collision: false, com: false, transparent: false, grid: true, shadows: true,
});

/** Un estado guardado (posiciones de las articulaciones y de los objetos), como los keyframes de MuJoCo. */
export type Keyframe = { id: string; name: string; json: string; savedAt: SwiftDate };
