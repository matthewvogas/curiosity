import { Files, join } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { Conversation, ConversationSummary } from "@/types/chat-types";

/** Conversaciones guardadas, una por archivo: chats/<robot>/<id>.json. */
const folder = (robotID: string) => join(AppPaths.chats, robotID.replace(/\//g, "_"));
const file = (robotID: string, id: string) => join(folder(robotID), `${id}.json`);

export const ChatQueries = {
  /** Las conversaciones de un robot, la más reciente primero. */
  async list(robotID: string): Promise<ConversationSummary[]> {
    const entries = (await Files.list(folder(robotID))).filter((e) => e.name.endsWith(".json"));
    const out: ConversationSummary[] = [];
    for (const e of entries) {
      const c = await Files.readJSON<Conversation>(e.path);
      if (c) out.push({ id: c.id, title: c.title, updatedAt: c.updatedAt });
    }
    return out.sort((a, b) => b.updatedAt - a.updatedAt);
  },
  load: (robotID: string, id: string) => Files.readJSON<Conversation>(file(robotID, id)),
  save: (c: Conversation) => Files.writeJSON(file(c.robotID, c.id), c),
  delete: (robotID: string, id: string) => Files.remove(file(robotID, id)),
};
