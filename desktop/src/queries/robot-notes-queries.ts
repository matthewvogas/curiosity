import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { Files, join } from "./native";
import { AppPaths } from "@/utils/app-paths";
import { RobotNotes, type RobotNotesFile } from "@/utils/robot-notes";

/** Las notas de cada robot: robot-notes/<robotID>.md (Markdown que también abre cualquier editor). */
export const RobotNotesQueries = {
  path: (robotID: string) => join(AppPaths.root, "robot-notes", RobotNotes.fileName(robotID)),

  async load(robotID: string): Promise<RobotNotesFile> {
    return RobotNotes.parse(await Files.readText(RobotNotesQueries.path(robotID)).catch(() => null));
  },

  save: (robotID: string, file: RobotNotesFile) => Files.writeText(RobotNotesQueries.path(robotID), RobotNotes.format(file)),

  async reveal(robotID: string) {
    const path = RobotNotesQueries.path(robotID);
    if (!(await Files.exists(path))) await RobotNotesQueries.save(robotID, { notes: "", learned: [] });
    await revealItemInDir(path);
  },
};
