import { Files, invoke, isMac, join } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { LossPoint, PolicyOption, TrainJob, TrainProgress } from "@/types/lerobot-types";

/**
 * Entrenamientos con `lerobot-train`: lanzarlos en segundo plano (siguen aunque se cierre la app), leer su
 * avance del registro y detenerlos. La lista se guarda en training/jobs.json.
 */
const jobsFile = () => join(AppPaths.training, "jobs.json");

export const TrainQueries = {
  jobs: async () => (await Files.readJSON<TrainJob[]>(jobsFile())) ?? [],
  save: (jobs: TrainJob[]) => Files.writeJSON(jobsFile(), jobs),

  /** Los argumentos de `lerobot-train` para un entrenamiento. */
  arguments(o: { dataset: string; datasetRoot?: string | null; policy: PolicyOption; steps: number; batchSize: number; outputDir: string; name: string }): string[] {
    const args = [
      `--dataset.repo_id=${o.dataset}`,
      `--output_dir=${o.outputDir}`,
      `--job_name=${o.name}`,
      "--policy.push_to_hub=false",
      `--steps=${o.steps}`,
      `--batch_size=${o.batchSize}`,
      `--save_freq=${o.steps > 5000 ? 5000 : o.steps}`,
      "--log_freq=200",
    ];
    // En una Mac, la GPU de Apple; en Windows y Linux, LeRobot elige (CUDA si hay, si no CPU).
    if (isMac()) args.push("--policy.device=mps");
    if (o.datasetRoot) args.push(`--dataset.root=${o.datasetRoot}`);
    args.push(o.policy.basePath ? `--policy.path=${o.policy.basePath}` : `--policy.type=${o.policy.id}`);
    return args;
  },

  /** Lanza el entrenamiento en su propio proceso (no muere con la app) y devuelve su pid. */
  launch: (python: string, args: string[], log: string, hubToken: string | null) =>
    invoke<number>("train_launch", { python, args, log, hubToken }),

  isAlive: (pid: number) => invoke<boolean>("proc_alive", { pid }),

  /** Como Ctrl+C: lo guardado en los checkpoints se conserva. */
  stop: (pid: number) => invoke<void>("proc_interrupt", { pid }),

  /** Otro entrenamiento de LeRobot corriendo en esta computadora (de la app o de la terminal). */
  anyRunning: () => invoke<boolean>("train_any_running"),

  modelPath: (job: TrainJob) => join(job.outputDir, "checkpoints", "last", "pretrained_model"),

  /** Los nombres de cámara con que se entrenó el modelo, en el orden de su config.json (p. ej. up, side). */
  async cameras(job: TrainJob): Promise<string[]> {
    const text = await Files.readText(join(TrainQueries.modelPath(job), "config.json"));
    const out: string[] = [];
    for (const m of text?.matchAll(/"observation\.images\.([\w-]+)"/g) ?? []) if (!out.includes(m[1])) out.push(m[1]);
    return out;
  },

  /** Avance según la barra y las líneas de pérdida de lerobot-train. */
  async progress(job: TrainJob): Promise<TrainProgress> {
    const out: TrainProgress = { step: 0, finished: false, running: false, hasModel: false };
    out.running = await TrainQueries.isAlive(job.pid);
    out.hasModel = await Files.exists(join(TrainQueries.modelPath(job), "config.json"));
    const text = await Files.tail(job.log, 200_000);
    if (!text) return out;
    const bars = [...text.matchAll(/(\d+)\/(\d+) \[([\d:]+)<([\d:?]+)/g)];
    const bar = bars.at(-1);
    if (bar) {
      out.step = Number(bar[1]);
      out.total = Number(bar[2]);
      out.elapsed = bar[3];
      out.remaining = bar[4];
    }
    const loss = [...text.matchAll(/\bloss:([\d.]+)/g)].at(-1);
    if (loss) out.loss = Number(loss[1]);
    out.finished = text.includes("End of training");
    const error = [...text.matchAll(/^\w*Error: .+$/gm)].at(-1);
    if (error) out.error = error[0];
    return out;
  },

  /** La curva de pérdida completa (lerobot-train escribe una línea cada log_freq pasos). */
  async history(job: TrainJob): Promise<LossPoint[]> {
    const text = await Files.readText(job.log);
    if (!text) return [];
    const points: LossPoint[] = [];
    const scales: Record<string, number> = { K: 1e3, M: 1e6, B: 1e9 };
    for (const line of text.split(/[\n\r]+/)) {
      if (!line.includes("loss:")) continue;
      const loss = line.match(/\bloss:([\d.]+)/);
      if (!loss) continue;
      // El paso exacto sale de la barra (200/20000 [...]); si no está, de «step:1.2K».
      const bar = line.match(/(\d+)\/\d+ \[/);
      const s = line.match(/\bstep:([\d.]+)([KMB]?)/);
      if (bar) points.push({ step: Number(bar[1]), loss: Number(loss[1]) });
      else if (s) points.push({ step: Math.round(Number(s[1]) * (scales[s[2]] ?? 1)), loss: Number(loss[1]) });
    }
    return points;
  },

  /** Las últimas líneas del registro, sin las actualizaciones de la barra de progreso. */
  async logTail(job: TrainJob, lines = 40): Promise<string[]> {
    const text = await Files.tail(job.log, 60_000);
    if (!text) return [];
    const all = text.split(/[\n\r]+/).filter(Boolean);
    return all.filter((l, i) => !l.startsWith("Training:") || i === all.length - 1).slice(-lines);
  },
};
