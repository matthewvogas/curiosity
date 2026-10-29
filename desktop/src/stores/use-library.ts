import { makeAutoObservable, runInAction } from "mobx";
import { LibraryQueries } from "@/queries/library-queries";
import type { LibraryCatalog, LibraryRobot } from "@/types/library-types";
import type { UseRobots } from "./use-robots";

/** La biblioteca de robots de MuJoCo Menagerie: buscar, filtrar y agregar (descargar) a mis robots. */
export class UseLibrary {
  catalog: LibraryCatalog | null = null;
  search = "";
  category: string | null = null;
  /** id del robot → fracción descargada (0…1). */
  downloading: Record<string, number> = {};
  error: string | null = null;
  /** Se agregó algún robot en esta visita a la biblioteca (para cerrar la hoja de «Agregar»). */
  isAddedAny = false;

  constructor(private robots: UseRobots) {
    makeAutoObservable<UseLibrary, "robots">(this, { robots: false });
  }

  /** Lee el catálogo incluido en la app (en Swift se leía en el init). */
  async load() {
    try {
      const catalog = await LibraryQueries.catalog();
      runInAction(() => (this.catalog = catalog));
    } catch (e) {
      runInAction(() => (this.error = `Couldn't read the library: ${e}`));
    }
  }

  get categories(): string[] {
    const seen: string[] = [];
    for (const r of this.catalog?.robots ?? []) if (!seen.includes(r.category)) seen.push(r.category);
    return seen;
  }

  get visible(): LibraryRobot[] {
    const q = this.search.trim().toLowerCase();
    return (this.catalog?.robots ?? []).filter(
      (r) =>
        (this.category == null || r.category === this.category) &&
        (!q || r.name.toLowerCase().includes(q) || r.id.toLowerCase().includes(q)),
    );
  }

  setSearch(search: string) {
    this.search = search;
  }

  setCategory(category: string | null) {
    this.category = category;
  }

  imageURL(robot: LibraryRobot): string | null {
    if (!this.catalog || !robot.image) return null;
    return LibraryQueries.rawURL(this.catalog, robot.image);
  }

  beginVisit() {
    this.isAddedAny = false;
    this.error = null;
  }

  isAdded(robot: LibraryRobot): boolean {
    return this.robots.robots.some((r) => r.id === `library.${robot.id}`);
  }

  /** Descarga el robot (si hace falta) y lo agrega a mis robots, ya abierto. */
  async add(robot: LibraryRobot) {
    const catalog = this.catalog;
    if (!catalog || this.downloading[robot.id] != null) return;
    this.error = null;
    this.downloading[robot.id] = 0;
    try {
      const path = await LibraryQueries.download(catalog, robot, (p) => runInAction(() => (this.downloading[robot.id] = p)));
      await this.robots.addFromLibrary(`library.${robot.id}`, robot.name, robot.category, path);
      runInAction(() => (this.isAddedAny = true));
    } catch (e) {
      runInAction(() => (this.error = `Couldn't download ${robot.name}: ${e instanceof Error ? e.message : String(e)}`));
    } finally {
      runInAction(() => delete this.downloading[robot.id]);
    }
  }
}
