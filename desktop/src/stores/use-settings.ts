import { makeAutoObservable, runInAction } from "mobx";
import { KeychainQueries } from "@/queries/keychain-queries";
import { PythonQueries } from "@/queries/python-queries";
import { AnthropicQueries } from "@/queries/anthropic-queries";
import { Preferences } from "@/queries/preferences";
import { AI_MODELS } from "@/types/chat-types";

const ANTHROPIC = "anthropic-api-key";
const HUB = "huggingface-token";

/** Ajustes: la IA (API key en el almacén seguro y modelo), LeRobot (su Python) y Hugging Face (token). */
export class UseSettings {
  /** El Python donde está instalado LeRobot (el de su entorno virtual). */
  lerobotPython = Preferences.get("lerobot.python", "");
  hasHubToken = false;
  hasAnthropicKey = false;
  modelID = Preferences.get("ai.model", AI_MODELS[0].id);
  /** Cuánto piensa el modelo: low · medium · high. */
  effort = Preferences.get("ai.effort", "medium");
  testing = false;
  testResult: { ok: boolean; message: string } | null = null;
  /** La ventana de ajustes abierta. */
  open = false;

  // Las keys se guardan solo en el almacén seguro; aquí, una copia en memoria para no pedirla cada vez.
  private anthropic: string | null = null;
  private hub: string | null = null;

  constructor() {
    makeAutoObservable<UseSettings, "anthropic" | "hub">(this, { anthropic: false, hub: false });
  }

  async load() {
    const [anthropic, hub] = await Promise.all([KeychainQueries.read(ANTHROPIC), KeychainQueries.read(HUB)]);
    // La primera vez se busca solo; si no aparece, se indica en Ajustes.
    const python = this.lerobotPython || (await PythonQueries.findLeRobot()) || "";
    runInAction(() => {
      this.anthropic = anthropic;
      this.hub = hub;
      this.hasAnthropicKey = !!anthropic;
      this.hasHubToken = !!hub;
      this.setLerobotPython(python);
    });
  }

  setLerobotPython(path: string) {
    this.lerobotPython = path;
    Preferences.set("lerobot.python", path);
  }
  setModelID(id: string) {
    this.modelID = id;
    Preferences.set("ai.model", id);
  }
  setEffort(e: string) {
    this.effort = e;
    Preferences.set("ai.effort", e);
  }
  setOpen(open: boolean) {
    this.open = open;
  }

  get hubToken(): string | null {
    return this.hub;
  }
  get anthropicKey(): string | null {
    return this.anthropic;
  }

  async saveHubToken(token: string) {
    const t = token.trim();
    if (!t) return;
    await KeychainQueries.save(HUB, t);
    runInAction(() => {
      this.hub = t;
      this.hasHubToken = true;
    });
  }

  async removeHubToken() {
    await KeychainQueries.delete(HUB);
    runInAction(() => {
      this.hub = null;
      this.hasHubToken = false;
    });
  }

  async saveAnthropicKey(key: string) {
    const k = key.trim();
    if (!k) return;
    await KeychainQueries.save(ANTHROPIC, k);
    runInAction(() => {
      this.anthropic = k;
      this.hasAnthropicKey = true;
      this.testResult = null;
    });
  }

  async removeAnthropicKey() {
    await KeychainQueries.delete(ANTHROPIC);
    runInAction(() => {
      this.anthropic = null;
      this.hasAnthropicKey = false;
      this.testResult = null;
    });
  }

  /** Una solicitud mínima para comprobar que la key y el modelo funcionan. */
  async testConnection() {
    const key = this.anthropic;
    if (!key) return;
    this.testing = true;
    try {
      await AnthropicQueries.createMessage(key, {
        model: this.modelID,
        max_tokens: 64,
        output_config: { effort: "low" },
        messages: [{ role: "user", content: "Reply only: ok" }],
      });
      runInAction(() => (this.testResult = { ok: true, message: "Connected" }));
    } catch (e) {
      runInAction(() => (this.testResult = { ok: false, message: e instanceof Error ? e.message : String(e) }));
    } finally {
      runInAction(() => (this.testing = false));
    }
  }
}
