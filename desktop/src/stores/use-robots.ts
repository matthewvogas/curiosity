import { makeAutoObservable, runInAction } from "mobx";
import { RobotQueries } from "@/queries/robot-queries";
import { Preferences } from "@/queries/preferences";
import type { Robot } from "@/types/robot-types";
import { swiftDate, uuid } from "@/utils/codable";
import { basename, dirname } from "@/queries/native";

/** Mis robots para simular: empieza vacía; se agregan el incluido, los de la biblioteca o un archivo. */
export class UseRobots {
  robots: Robot[] = [];
  error: string | null = null;
  selectedID: string | null = Preferences.get<string | null>("robots.selected", null);
  /** Los robots que vienen con la app (para el catálogo de «Abrir simulador»). */
  included: Robot[] = [];

  constructor() {
    makeAutoObservable(this);
  }

  get selected(): Robot | null {
    return this.robots.find((r) => r.id === this.selectedID) ?? null;
  }

  select(id: string | null) {
    this.selectedID = id;
    Preferences.set("robots.selected", id);
  }

  async load() {
    const [mine, included] = await Promise.all([RobotQueries.imported(), RobotQueries.bundled()]);
    runInAction(() => {
      this.robots = [...mine].sort((a, b) => b.addedAt - a.addedAt);
      this.included = included;
      if (!this.selected) this.selectedID = null;
    });
  }

  private async save(list: Robot[]): Promise<boolean> {
    try {
      await RobotQueries.saveImported(list);
      await this.load();
      return true;
    } catch (e) {
      runInAction(() => (this.error = `Couldn't save the list: ${e}`));
      return false;
    }
  }

  /** Agrega (o abre, si ya estaba) un robot incluido en la app. */
  async addIncluded(robot: Robot) {
    const mine = await RobotQueries.imported();
    if (!mine.some((r) => r.id === robot.id)) {
      if (!(await this.save([...mine, { ...robot, addedAt: swiftDate.now() }]))) return;
    }
    this.select(robot.id);
  }

  /** Importa un URDF o MJCF del disco. Sus mallas se leen desde su carpeta; no se copia nada. */
  async importModel(path: string) {
    this.error = null;
    const name = await RobotQueries.modelName(path);
    if (!name) {
      runInAction(() => (this.error = "That file doesn't look like a URDF or MJCF."));
      return;
    }
    const profile = await RobotQueries.readProfile(path);
    const imported = await RobotQueries.imported();
    const existing = imported.find((r) => r.urdfPath === path);
    if (existing) return this.select(existing.id);
    const robot: Robot = {
      id: uuid(),
      name: profile.name ?? name,
      summary: profile.description ?? basename(dirname(path)),
      source: "file",
      urdfPath: path,
      license: profile.license,
      addedAt: swiftDate.now(),
    };
    if (await this.save([...imported, robot])) this.select(robot.id);
  }

  /** Un robot recién descargado de la biblioteca: se agrega (o se reabre si ya estaba). */
  async addFromLibrary(id: string, name: string, category: string, modelPath: string) {
    const imported = await RobotQueries.imported();
    if (!imported.some((r) => r.id === id)) {
      const robot: Robot = { id, name, summary: category, source: "library", urdfPath: modelPath, license: "MuJoCo Menagerie", addedAt: swiftDate.now() };
      if (!(await this.save([...imported, robot]))) return;
    }
    this.select(id);
  }

  /** Lo quita de la lista (los archivos descargados se quedan en el disco). */
  async remove(robot: Robot) {
    await this.save((await RobotQueries.imported()).filter((r) => r.id !== robot.id));
    if (this.selectedID === robot.id) this.select(null);
  }

  profile(robot: Robot): Promise<Record<string, any>> {
    return RobotQueries.readProfile(RobotQueries.filePath(robot));
  }
}
