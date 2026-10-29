import { makeAutoObservable, runInAction } from "mobx";
import { TrainQueries } from "@/queries/train-queries";
import { join } from "@/queries/native";
import { AppPaths } from "@/utils/app-paths";
import { swiftDate } from "@/utils/codable";
import type { UseSettings } from "@/stores/use-settings";
import type { PolicyOption, TrainJob, TrainProgress, TrainWatch } from "@/types/lerobot-types";

/** Entrenamientos con lerobot-train: lanzarlos, ver su avance y detenerlos. Siguen aunque se cierre la app. */
export class UseTraining {
  jobs: TrainJob[] = [];
  progress: Record<string, TrainProgress> = {};
  message: string | null = null;
  /** El entrenamiento abierto en vivo (curva y registro); null si no se está mirando ninguno. */
  watched: TrainWatch | null = null;
  private poller: ReturnType<typeof setInterval> | null = null;
  private refreshing = false;

  constructor(private settings: UseSettings) {
    makeAutoObservable<UseTraining, "settings" | "poller" | "refreshing">(this, { settings: false, poller: false, refreshing: false });
    void this.load();
    this.poller = setInterval(() => void this.refresh(), 3000);
  }

  /** Lee la lista guardada y su avance (la versión de Swift lo hacía al crearse). */
  async load() {
    const jobs = await TrainQueries.jobs();
    runInAction(() => (this.jobs = jobs));
    await this.refresh();
  }

  dispose() {
    if (this.poller) clearInterval(this.poller);
    this.poller = null;
  }

  get finished(): TrainJob[] {
    return this.jobs.filter((j) => this.progress[j.name]?.hasModel === true);
  }

  async refresh() {
    if (this.refreshing) return;
    this.refreshing = true;
    try {
      const jobs = this.jobs.slice();
      const entries = await Promise.all(jobs.map(async (j) => [j.name, await TrainQueries.progress(j)] as const));
      const next = Object.fromEntries(entries);
      runInAction(() => {
        if (JSON.stringify(next) !== JSON.stringify(this.progress)) this.progress = next;
      });
      const name = this.watched?.name;
      const job = name ? this.jobs.find((j) => j.name === name) : undefined;
      if (name && job) {
        const [history, log] = await Promise.all([TrainQueries.history(job), TrainQueries.logTail(job)]);
        const w: TrainWatch = { name, history, log };
        runInAction(() => {
          // Solo si sigue mirando el mismo y algo cambió.
          if (this.watched?.name === name && JSON.stringify(w) !== JSON.stringify(this.watched)) this.watched = w;
        });
      }
    } catch {
      /* el siguiente ciclo lo vuelve a intentar */
    } finally {
      this.refreshing = false;
    }
  }

  /** Empieza (o deja) de mirar un entrenamiento en vivo. */
  watch(name: string | null) {
    this.watched = name ? { name, history: [], log: [] } : null;
    void this.refresh();
  }

  /** Lanza un entrenamiento. `dataset` es un repo_id (local/… para los de esta computadora, usuario/… del Hub). */
  async start(name: string, dataset: string, datasetRoot: string | null, policy: PolicyOption, steps: number, batchSize: number) {
    this.message = null;
    if (!AppPaths.isValidName(name)) {
      this.message = "The name can only have letters, numbers, - and _.";
      return;
    }
    if (this.jobs.some((j) => j.name === name)) {
      this.message = `There's already a training called “${name}”.`;
      return;
    }
    try {
      if (await TrainQueries.anyRunning()) {
        runInAction(() => (this.message = "A training is already running."));
        return;
      }
      const output = join(AppPaths.training, name);
      const log = join(AppPaths.logs, `${name}.log`);
      const args = TrainQueries.arguments({ dataset, datasetRoot, policy, steps, batchSize, outputDir: output, name });
      const pid = await TrainQueries.launch(this.settings.lerobotPython, args, log, this.settings.hubToken);
      const job: TrainJob = {
        name, dataset, datasetRoot, policy: policy.id, steps, batchSize, started: swiftDate.now(), pid, log, outputDir: output,
      };
      runInAction(() => this.jobs.unshift(job));
      await TrainQueries.save(this.jobs.slice());
      await this.refresh();
    } catch (e) {
      runInAction(() => (this.message = e instanceof Error ? e.message : String(e)));
    }
  }

  stop(job: TrainJob) {
    void TrainQueries.stop(job.pid).catch(() => {});
    const j = this.jobs.find((x) => x.name === job.name);
    if (j) j.stopped = swiftDate.now();
    void TrainQueries.save(this.jobs.slice());
  }

  remove(job: TrainJob) {
    this.jobs = this.jobs.filter((j) => j.name !== job.name);
    void TrainQueries.save(this.jobs.slice());
    const { [job.name]: _, ...rest } = this.progress;
    this.progress = rest;
  }
}
