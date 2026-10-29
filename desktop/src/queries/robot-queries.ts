import { Files, join, nativePaths } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { Keyframe, Robot } from "@/types/robot-types";
import { swiftDate } from "@/utils/codable";

/** La biblioteca de robots en disco: los incluidos en la app y los importados por la persona. */
export const RobotQueries = {
  /** Robots que vienen con la app (resources/robots/<id>/<id>.urdf + <id>.studio.json). */
  async bundled(): Promise<Robot[]> {
    const root = join(AppPaths.resources, "robots");
    const ids = (await Files.list(root)).filter((e) => e.isDir).map((e) => e.name).sort();
    const out: Robot[] = [];
    for (const id of ids) {
      const urdf = join(root, id, `${id}.urdf`);
      if (!(await Files.exists(urdf))) continue;
      const profile = await RobotQueries.readProfile(urdf);
      out.push({
        id: `bundled.${id}`,
        name: profile.name ?? id,
        summary: profile.description ?? "",
        source: "bundled",
        urdfPath: `robots/${id}/${id}.urdf`,
        license: profile.license,
        addedAt: swiftDate.distantPast,
      });
    }
    return out;
  },

  /** Mis robots (robots.json): incluidos agregados, de la biblioteca e importados. */
  async imported(): Promise<Robot[]> {
    return (await Files.readJSON<Robot[]>(join(AppPaths.root, "robots.json"))) ?? [];
  },

  saveImported: (robots: Robot[]) => Files.writeJSON(join(AppPaths.root, "robots.json"), robots),

  /** El archivo del modelo en disco (para leer su perfil o mostrarlo en el explorador de archivos). */
  filePath(robot: Robot): string {
    return robot.source === "bundled" ? join(AppPaths.resources, ...robot.urdfPath.split("/")) : robot.urdfPath;
  },

  /** Perfil opcional junto al modelo (<nombre>.studio.json): cámaras, actuadores, escena inicial. */
  async readProfile(modelPath: string): Promise<Record<string, any>> {
    const profile = modelPath.replace(/\.[^.\\/]+$/, "") + ".studio.json";
    return (await Files.readJSON<Record<string, any>>(profile)) ?? {};
  },

  // Keyframes: por robot, en keyframes/<id>.json
  keyframesFile: (robotID: string) => join(AppPaths.root, "keyframes", `${robotID.replace(/\//g, "_")}.json`),
  async keyframes(robotID: string): Promise<Keyframe[]> {
    return (await Files.readJSON<Keyframe[]>(RobotQueries.keyframesFile(robotID))) ?? [];
  },
  saveKeyframes: (keys: Keyframe[], robotID: string) => Files.writeJSON(RobotQueries.keyframesFile(robotID), keys),

  /** Guarda una captura (PNG en base64) en Imágenes/Curiosity y devuelve dónde quedó. */
  async saveScreenshot(pngBase64: string, robotName: string): Promise<string> {
    const stamp = new Date().toISOString().slice(0, 19).replace(/:/g, ".").replace("T", " ");
    const path = join(nativePaths().pictures, "Curiosity", `${robotName} ${stamp}.png`);
    await Files.writeBase64(path, pngBase64);
    return path;
  },

  /** Nombre del robot según el propio archivo: <robot name="…"> (URDF) o <mujoco model="…"> (MJCF). */
  async modelName(path: string): Promise<string | null> {
    const text = await Files.readText(path);
    if (!text) return null;
    for (const re of [/<robot[^>]*\sname\s*=\s*"([^"]+)"/, /<mujoco[^>]*\smodel\s*=\s*"([^"]+)"/]) {
      const m = text.match(re);
      if (m) return m[1];
    }
    if (text.includes("<mujoco")) return path.split(/[\\/]/).pop()!.replace(/\.[^.]+$/, "");
    return null;
  },
};
