import { Files, invoke, join, on } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { LibraryCatalog, LibraryRobot } from "@/types/library-types";

/**
 * La biblioteca de MuJoCo Menagerie: el catálogo incluido en la app y la descarga de cada robot (desde
 * GitHub, en la versión fija del catálogo) a <datos>/library.
 */
export const LibraryQueries = {
  catalog: () => Files.readJSON<LibraryCatalog>(join(AppPaths.resources, "library", "menagerie.json")),

  rawURL: (c: LibraryCatalog, path: string) => `https://raw.githubusercontent.com/${c.source}/${c.commit}/${path}`,

  folder: (c: LibraryCatalog) => join(AppPaths.root, "library", c.commit.slice(0, 12)),

  /** Dónde queda el MJCF del robot una vez descargado. */
  localModel: (c: LibraryCatalog, r: LibraryRobot) => join(LibraryQueries.folder(c), ...r.xml.split("/")),

  /** Descarga los archivos que falten (8 a la vez). `progress` recibe la fracción descargada. */
  async download(c: LibraryCatalog, r: LibraryRobot, progress: (f: number) => void): Promise<string> {
    const stop = await on<number>("download://progress", progress);
    try {
      await invoke("download_files", {
        baseUrl: `https://raw.githubusercontent.com/${c.source}/${c.commit}`,
        files: r.files,
        dest: LibraryQueries.folder(c),
      });
    } finally {
      stop();
    }
    return LibraryQueries.localModel(c, r);
  },
};
