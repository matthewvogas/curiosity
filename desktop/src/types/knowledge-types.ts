import type { SwiftDate } from "@/utils/codable";

/**
 * Lo que la IA aprendió estudiando demostraciones (de esta computadora o de Hugging Face), sin entrenar
 * nada: cómo se hace la tarea por etapas, poses clave y tramos que se pueden reproducir en el robot.
 */
export type KnowledgePackage = {
  id: string;
  /** De dónde salió: repo_id del dataset (local/… o usuario/…). */
  source: string;
  title: string;
  createdAt: SwiftDate;
  summary: string;
  stages: { name: string; goal: string; check: string }[];
  poses: { name: string; joints: Record<string, number>; note: string }[];
  segments: { name: string; episode: number; from: number; to: number; note: string }[];
  tips: string[];
  /** Trayectorias de las demostraciones estudiadas: episodio → [[t, articulaciones…]], en el orden de `joints`. */
  trajectories: Record<string, number[][]>;
  /** Las articulaciones de las trayectorias, en orden. Los paquetes viejos no la tienen: eran del SO-101. */
  joints?: string[];
  /** Fotos de referencia (momentos clave), JPEG en base64. */
  pictures: { label: string; jpeg: string }[];
};

export const jointOrder = (p: KnowledgePackage) =>
  p.joints ?? ["shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper"];

/** Lo que el puente sacó de un dataset para estudiarlo. */
export type StudyMaterial = {
  repoID: string;
  info: Record<string, any>;
  joints: string[];
  episodes: { index: number; task: string; duration: number; trajectory: number[][]; events: Record<string, any>[] }[];
  pictures: { episode: number; label: string; jpeg: string }[];
};
