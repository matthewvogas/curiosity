import { join, nativePaths } from "@/queries/native";

/** Dónde guarda la app lo que produce (Application Support/Curiosity en macOS, %APPDATA%\Curiosity en Windows). */
export const AppPaths = {
  get root() {
    return nativePaths().root;
  },
  /** Recursos incluidos con la app (studio/, robots/, library/, bridge/). */
  get resources() {
    return nativePaths().resources;
  },
  /** Datasets grabados con la app. */
  get datasets() {
    return join(this.root, "datasets");
  },
  /** Modelos entrenados con la app (uno por carpeta). */
  get training() {
    return join(this.root, "training");
  },
  /** Registros de los entrenamientos. */
  get logs() {
    return join(this.root, "logs");
  },
  get knowledge() {
    return join(this.root, "knowledge");
  },
  /** La página de notas de cada tarea. */
  get notes() {
    return join(this.root, "notes");
  },
  get chats() {
    return join(this.root, "chats");
  },
  /** Donde LeRobot guarda los datasets descargados del Hub. */
  get hubCache() {
    return join(nativePaths().home, ".cache", "huggingface", "lerobot");
  },
  /** Nombre válido para un dataset o un entrenamiento. */
  isValidName(name: string): boolean {
    return /^[A-Za-z0-9_-]{1,60}$/.test(name);
  },
};
