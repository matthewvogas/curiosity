import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/** Lo que cambia según el sistema: carpetas, separador y nombre (macos · windows · linux). */
export type AppPathsInfo = {
  root: string;
  resources: string;
  pictures: string;
  home: string;
  platform: "macos" | "windows" | "linux" | string;
  separator: string;
  /** La ventana tiene el blur del sistema detrás; si no, la app usa fondos opacos. */
  translucent: boolean;
};

let paths: AppPathsInfo | null = null;

/** Se llama una vez al arrancar (main.tsx), antes de crear los stores. */
export async function loadNativePaths(): Promise<AppPathsInfo> {
  paths = await invoke<AppPathsInfo>("app_paths");
  document.documentElement.dataset.translucent = String(paths.translucent);
  return paths;
}

export function nativePaths(): AppPathsInfo {
  if (!paths) throw new Error("loadNativePaths() wasn't called");
  return paths;
}

export const isWindows = () => nativePaths().platform === "windows";
export const isMac = () => nativePaths().platform === "macos";

/** Une partes de una ruta con el separador del sistema. */
export function join(...parts: string[]): string {
  const sep = paths?.separator ?? "/";
  return parts
    .filter((p) => p !== "")
    .map((p, i) => (i === 0 ? p.replace(/[\\/]+$/, "") : p.replace(/^[\\/]+|[\\/]+$/g, "")))
    .join(sep);
}

export function basename(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

export function dirname(path: string): string {
  const i = Math.max(path.lastIndexOf("/"), path.lastIndexOf("\\"));
  return i <= 0 ? path : path.slice(0, i);
}

// ---------- Archivos (sin estado) ----------

export type DirEntry = { name: string; path: string; isDir: boolean; modified: number };

export const Files = {
  readText: (path: string) => invoke<string | null>("fs_read_text", { path }),
  readBase64: (path: string) => invoke<string | null>("fs_read_base64", { path }),
  writeText: (path: string, contents: string) => invoke<void>("fs_write_text", { path, contents }),
  writeBase64: (path: string, data: string) => invoke<void>("fs_write_base64", { path, data }),
  list: (path: string) => invoke<DirEntry[]>("fs_list", { path }),
  exists: (path: string) => invoke<boolean>("fs_exists", { path }),
  remove: (path: string) => invoke<void>("fs_remove", { path }),
  tail: (path: string, size: number) => invoke<string | null>("fs_tail", { path, size }),

  async readJSON<T>(path: string): Promise<T | null> {
    const text = await Files.readText(path);
    if (text == null) return null;
    try {
      return JSON.parse(text) as T;
    } catch {
      return null;
    }
  },
  writeJSON: (path: string, value: unknown) => Files.writeText(path, JSON.stringify(value)),
};

export function on<T>(event: string, handler: (payload: T) => void): Promise<UnlistenFn> {
  return listen<T>(event, (e) => handler(e.payload));
}

export { invoke };
