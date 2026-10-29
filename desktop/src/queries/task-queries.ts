import { Files, join } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { TeachTask } from "@/types/task-types";

/** Las tareas guardadas (tasks.json). */
export const TaskQueries = {
  load: async () => (await Files.readJSON<TeachTask[]>(join(AppPaths.root, "tasks.json"))) ?? [],
  save: (tasks: TeachTask[]) => Files.writeJSON(join(AppPaths.root, "tasks.json"), tasks),
};
