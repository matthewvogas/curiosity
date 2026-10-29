import { makeAutoObservable, runInAction } from "mobx";
import { AnthropicQueries } from "@/queries/anthropic-queries";
import { KnowledgeQueries } from "@/queries/knowledge-queries";
import { Preferences } from "@/queries/preferences";
import type { KnowledgePackage, StudyMaterial } from "@/types/knowledge-types";
import { KnowledgePrompt } from "@/utils/knowledge-prompt";
import type { UseLeRobot } from "./use-lerobot";
import type { UseSettings } from "./use-settings";

type Json = Record<string, any>;

/**
 * Paquetes de conocimiento: la IA estudia demostraciones (de esta computadora o de Hugging Face) y escribe cómo se
 * hace la tarea. El paquete activo se usa en vivo, sin entrenar nada.
 */
export class UseKnowledge {
  packages: KnowledgePackage[] = [];
  /** Qué está haciendo el estudio ahora («Bajando las demostraciones…»), o null. */
  studying: string | null = null;
  error: string | null = null;
  activeID: string | null = Preferences.get<string | null>("knowledge.active", null);

  private readonly settings: UseSettings;
  private readonly lerobot: UseLeRobot;

  constructor(settings: UseSettings, lerobot: UseLeRobot) {
    this.settings = settings;
    this.lerobot = lerobot;
    makeAutoObservable<UseKnowledge, "settings" | "lerobot">(this, { settings: false, lerobot: false });
    void this.load();
  }

  async load() {
    const list = await KnowledgeQueries.list().catch(() => [] as KnowledgePackage[]);
    runInAction(() => (this.packages = list));
  }

  get active(): KnowledgePackage | null {
    return this.packages.find((p) => p.id === this.activeID) ?? null;
  }

  setActiveID(id: string | null) {
    this.activeID = id;
    Preferences.set("knowledge.active", id);
  }

  /** Estudia un dataset (`root` para los de esta computadora; sin él se baja del Hub solo lo necesario). */
  async study(repoID: string, root: string | null, robotType: string | null, followerID: string | null) {
    if (this.studying != null) return;
    const key = this.settings.anthropicKey;
    if (!key) {
      this.error = "Add your API key in Settings.";
      return;
    }
    this.error = null;
    this.studying = root == null ? "Downloading some demonstrations from Hugging Face…" : "Reading the demonstrations…";
    try {
      if (this.lerobot.status !== "ready") await this.lerobot.start();
      const args: Json = { repo_id: repoID, episodes: 6 };
      if (root != null) args.root = root;
      if (followerID != null) args.follower_id = followerID;
      if (robotType != null) args.robot_type = robotType;
      const material = UseKnowledge.material(await this.lerobot.request("study", args), repoID);
      if (material.episodes.length === 0) throw new Error("The dataset has no readable demonstrations.");

      runInAction(() => (this.studying = `Studying ${material.episodes.length} demonstrations…`));
      const response = await AnthropicQueries.createMessage(key, {
        model: this.settings.modelID,
        max_tokens: 16000,
        system: `${KnowledgePrompt.studySystem}\n\nAnswer only by calling write_package, exactly once.`,
        tools: [KnowledgePrompt.writePackage],
        // Los modelos actuales (Opus 5.5, Sonnet 5.5, Fable 5.1) no aceptan forzar la herramienta: se le pide.
        tool_choice: { type: "auto" },
        messages: [{ role: "user", content: KnowledgePrompt.studyMessage(material) }],
      });
      const input = ((response.content as Json[]) ?? []).find((b) => b.type === "tool_use")?.input;
      if (!input || typeof input !== "object") throw new Error("The AI didn't write the package.");
      const pkg = KnowledgePrompt.package(input, material);
      await KnowledgeQueries.save(pkg);
      runInAction(() => {
        this.packages.unshift(pkg);
        this.setActiveID(pkg.id);
      });
    } catch (e) {
      runInAction(() => (this.error = e instanceof Error ? e.message : String(e)));
    } finally {
      runInAction(() => (this.studying = null));
    }
  }

  remove(id: string) {
    void KnowledgeQueries.delete(id);
    this.packages = this.packages.filter((p) => p.id !== id);
    if (this.activeID === id) this.setActiveID(null);
  }

  private static material(r: Json, repoID: string): StudyMaterial {
    const nums = (v: unknown) => (Array.isArray(v) ? v.map((x) => (typeof x === "number" ? x : 0)) : []);
    const episodes = ((r.episodes as Json[]) ?? []).map((e) => ({
      index: typeof e.episode === "number" ? Math.trunc(e.episode) : 0,
      task: typeof e.task === "string" ? e.task : "",
      duration: typeof e.duration_s === "number" ? e.duration_s : 0,
      trajectory: (Array.isArray(e.trajectory) ? e.trajectory : []).map(nums),
      events: Array.isArray(e.gripper_events) ? e.gripper_events : [],
    }));
    const pictures = ((r.keyframes as Json[]) ?? []).flatMap((k) =>
      typeof k.jpeg === "string"
        ? [{ episode: typeof k.episode === "number" ? Math.trunc(k.episode) : 0, label: typeof k.label === "string" ? k.label : "", jpeg: k.jpeg as string }]
        : [],
    );
    return { repoID, info: r, joints: Array.isArray(r.joints) ? r.joints : [], episodes, pictures };
  }
}
