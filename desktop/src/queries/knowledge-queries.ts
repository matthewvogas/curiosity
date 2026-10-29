import { Files, join } from "./native";
import { AppPaths } from "@/utils/app-paths";
import type { KnowledgePackage } from "@/types/knowledge-types";

/** Los paquetes de conocimiento en disco: knowledge/<id>.json. */
export const KnowledgeQueries = {
  async list(): Promise<KnowledgePackage[]> {
    const entries = (await Files.list(AppPaths.knowledge)).filter((e) => e.name.endsWith(".json"));
    const out: KnowledgePackage[] = [];
    for (const e of entries) {
      const p = await Files.readJSON<KnowledgePackage>(e.path);
      if (p) out.push(p);
    }
    return out.sort((a, b) => b.createdAt - a.createdAt);
  },
  save: (p: KnowledgePackage) => Files.writeJSON(join(AppPaths.knowledge, `${p.id}.json`), p),
  delete: (id: string) => Files.remove(join(AppPaths.knowledge, `${id}.json`)),
};
