import type { SwiftDate } from "@/utils/codable";

/** Una tarea que se le enseña al robot real: sus demostraciones (un dataset) y el modelo que se entrena. */
export type TeachTask = {
  id: string;
  deviceID: string;
  /** Lo que debe hacer, en palabras («Pon el cubo rojo en el vaso»). */
  title: string;
  /** Dataset propio (carpeta en datasets/) o, si `hubDataset`, un repo de Hugging Face. */
  dataset: string;
  hubDataset: boolean;
  createdAt: SwiftDate;
  // Opciones (valores iniciales; cada tarea los cambia)
  episodes: number;
  episodeSeconds: number;
  resetSeconds: number;
  policy: string;
  steps: number;
  batchSize: number;
  runSeconds: number;
};

export const taskDefaults = { hubDataset: false, episodes: 50, episodeSeconds: 60, resetSeconds: 10, policy: "act", steps: 20_000, batchSize: 8, runSeconds: 60 };

/** Nombre del entrenamiento de esta tarea. */
export const trainName = (t: TeachTask) => `${t.policy}_${t.dataset.replace(/\//g, "_")}`;
/** repo_id para LeRobot. */
export const repoID = (t: TeachTask) => (t.hubDataset ? t.dataset : `local/${t.dataset}`);
