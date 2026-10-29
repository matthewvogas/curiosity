import { makeAutoObservable, runInAction } from "mobx";
import { TaskQueries } from "@/queries/task-queries";
import { Files } from "@/queries/native";
import { Preferences } from "@/queries/preferences";
import { AppPaths } from "@/utils/app-paths";
import { Naming } from "@/utils/naming";
import { swiftDate, uuid } from "@/utils/codable";
import { taskDefaults, type TeachTask } from "@/types/task-types";

/** Las tareas que se le enseñan a cada robot real y cuál está abierta. */
export class UseTasks {
  tasks: TeachTask[] = [];
  /** La tarea abierta; sin ninguna, se ve el resumen del robot. Se recuerda al volver a abrir la app. */
  selectedID: string | null = Preferences.get<string | null>("tasks.open", null);
  /** El robot para el que se está escribiendo una tarea nueva (abre la hoja). */
  composingFor: string | null = null;

  constructor() {
    makeAutoObservable(this);
  }

  async load() {
    const tasks = await TaskQueries.load();
    runInAction(() => (this.tasks = tasks));
  }

  select(id: string | null) {
    this.selectedID = id;
    Preferences.set("tasks.open", id);
  }

  setComposingFor(deviceID: string | null) {
    this.composingFor = deviceID;
  }

  tasksFor(deviceID: string): TeachTask[] {
    return this.tasks.filter((t) => t.deviceID === deviceID).sort((a, b) => b.createdAt - a.createdAt);
  }

  selectedFor(deviceID: string): TeachTask | null {
    return this.tasksFor(deviceID).find((t) => t.id === this.selectedID) ?? null;
  }

  /** Una tarea nueva: su dataset se nombra a partir de lo que debe hacer. */
  async add(title: string, deviceID: string): Promise<TeachTask> {
    const onDisk = await Files.list(AppPaths.datasets).catch(() => []);
    const taken = new Set([...this.tasks.map((t) => t.dataset), ...onDisk.map((e) => e.name)]);
    const clean = title.trim();
    const task: TeachTask = {
      ...taskDefaults,
      id: uuid(),
      deviceID,
      title: clean,
      dataset: Naming.unique(Naming.slug(clean), taken),
      createdAt: swiftDate.now(),
    };
    runInAction(() => this.tasks.push(task));
    this.persist();
    this.select(task.id);
    return task;
  }

  update(id: string, change: (t: TeachTask) => void) {
    const t = this.tasks.find((t) => t.id === id);
    if (!t) return;
    change(t);
    this.persist();
  }

  /** Quita la tarea de la lista (su dataset y su modelo se quedan en el disco). */
  remove(id: string) {
    this.tasks = this.tasks.filter((t) => t.id !== id);
    this.persist();
    if (this.selectedID === id) this.select(null);
  }

  private persist() {
    void TaskQueries.save(this.tasks.slice());
  }
}
