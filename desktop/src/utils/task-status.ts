import type { DatasetInfo, TrainJob, TrainProgress } from "@/types/lerobot-types";
import { progressFraction } from "@/types/lerobot-types";
import { trainName, type TeachTask } from "@/types/task-types";

/** En qué va una tarea: se deduce de sus demostraciones grabadas y de su entrenamiento. */
export type TaskPhase = "demos" | "training" | "learned";

export class TaskStatus {
  constructor(public demos: number, public job: TrainJob | null, public progress: TrainProgress | null) {}

  get isTraining() {
    return this.progress?.running === true;
  }
  get hasModel() {
    return this.progress?.hasModel === true;
  }
  get phase(): TaskPhase {
    return this.isTraining ? "training" : this.hasModel ? "learned" : "demos";
  }

  /** Lo que se ve en la barra lateral y en las tarjetas. */
  summary(task: TeachTask): string {
    if (this.isTraining) return `Training · ${Math.round((this.progress ? progressFraction(this.progress) : 0) * 100)} %`;
    if (this.hasModel) return "Learned";
    if (task.hubDataset) return "Data from Hugging Face";
    return this.demos === 0 ? "No demonstrations" : `${this.demos} of ${task.episodes} demonstrations`;
  }

  static of(task: TeachTask, datasets: DatasetInfo[], jobs: TrainJob[], progress: Record<string, TrainProgress>): TaskStatus {
    const demos = datasets.find((d) => d.source === (task.hubDataset ? "hub" : "local") && d.name === task.dataset)?.episodes ?? 0;
    const name = trainName(task);
    const job = jobs.find((j) => j.name === name || j.name.startsWith(name + "_")) ?? null;
    return new TaskStatus(demos, job, job ? progress[job.name] ?? null : null);
  }
}
