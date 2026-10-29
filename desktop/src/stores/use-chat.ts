import { makeAutoObservable } from "mobx";
import { AnthropicQueries } from "@/queries/anthropic-queries";
import { ChatQueries } from "@/queries/chat-queries";
import { RobotNotesQueries } from "@/queries/robot-notes-queries";
import { RobotNotes } from "@/utils/robot-notes";
import type { ChatBody, ChatItem, ChatItemKind, ChatToolOutput, ConversationSummary } from "@/types/chat-types";
import { Item } from "@/types/chat-types";
import { swiftDate, utf8Base64, uuid } from "@/utils/codable";
import type { UseSettings } from "./use-settings";

type Json = Record<string, any>;

/** Un ChatBody puede recibir, además, la cancelación (como la Task de Swift) para soltar lo que esté haciendo. */
type RunWithSignal = (name: string, input: Json, signal?: AbortSignal) => Promise<ChatToolOutput>;

const MAX_TURNS = 24;

const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

/**
 * La conversación con la IA que maneja un robot (simulado o real, según su `ChatBody`): manda mensajes,
 * corre las herramientas que la IA pide y repite hasta que termina. Lo que mueve un robot real espera
 * a que la persona lo apruebe en el chat.
 */
export class UseChat {
  items: ChatItem[] = [];
  isRunning = false;
  error: string | null = null;
  /** Conversaciones anteriores con este robot (la más reciente primero). */
  conversations: ConversationSummary[] = [];
  conversationID = uuid();
  robotID = "";

  /**
   * Historia en el formato de la API. Solo se agrega al final (las respuestas van completas,
   * con sus bloques de pensamiento, como pide la API).
   */
  private history: Json[] = [];
  private robotName = "";
  /** La aprobación que se está esperando (se responde con approve / reject). */
  private waitingApproval: ((ok: boolean) => void) | null = null;
  /** La vuelta en curso (su cancelación). */
  private task: AbortController | null = null;

  constructor(
    private settings: UseSettings,
    private body: ChatBody,
  ) {
    makeAutoObservable<UseChat, "history" | "waitingApproval" | "task" | "settings" | "body">(this, {
      history: false,
      waitingApproval: false,
      task: false,
      settings: false,
      body: false,
    });
  }

  approve() {
    this.answer(true);
  }
  reject() {
    this.answer(false);
  }

  private answer(ok: boolean) {
    const waiting = this.waitingApproval;
    this.waitingApproval = null;
    waiting?.(ok);
  }

  /** Conversación nueva (al cambiar de robot o con «Nueva conversación»). Se guarda al primer mensaje. */
  reset(robotName: string, robotID: string) {
    this.stop();
    this.robotName = robotName;
    this.robotID = robotID;
    this.conversationID = uuid();
    this.items = [];
    this.history = [];
    this.error = null;
    this.conversations = [];
    ChatQueries.list(robotID)
      .then((list) => {
        if (this.robotID === robotID) this.conversations = list;
      })
      .catch(() => {});
  }

  /** Retoma una conversación guardada. */
  async open(id: string) {
    const robotID = this.robotID;
    const c = await ChatQueries.load(robotID, id).catch(() => null);
    if (!c || this.robotID !== robotID) return;
    this.stop();
    this.conversationID = c.id;
    this.items = c.items;
    try {
      const parsed = JSON.parse(utf8Base64.decode(c.history));
      this.history = Array.isArray(parsed) ? parsed : [];
    } catch {
      this.history = [];
    }
    this.error = null;
  }

  delete(id: string) {
    ChatQueries.delete(this.robotID, id).catch(() => {});
    this.conversations = this.conversations.filter((c) => c.id !== id);
    if (id === this.conversationID) this.reset(this.robotName, this.robotID);
  }

  send(text: string) {
    const trimmed = text.trim();
    if (!trimmed || this.isRunning) return;
    const key = this.settings.anthropicKey;
    if (!key) {
      this.error = "Add your API key in Settings to talk to the robot.";
      return;
    }
    const system = this.body.chatSystemPrompt(this.robotName);
    if (system == null) {
      this.error = this.body.chatNotReady;
      return;
    }
    this.error = null;
    this.items.push({ id: uuid(), kind: Item.user(trimmed) });
    this.history.push({ role: "user", content: trimmed });
    this.persist();
    const task = new AbortController();
    this.task = task;
    void this.run(key, system, task.signal);
  }

  stop() {
    this.answer(false);
    this.task?.abort();
    this.task = null;
    this.isRunning = false;
    // Las acciones a medio correr quedan como interrumpidas.
    let interrupted = false;
    this.items.forEach((item, i) => {
      const k = item.kind;
      if ("action" in k && k.action.running) {
        this.items[i] = { ...item, kind: Item.action(k.action.title, k.action.detail, false, true) };
        interrupted = true;
      }
      if ("approval" in k && k.approval.state === "pending") {
        this.items[i] = { ...item, kind: Item.approval(k.approval.title, k.approval.detail, "rejected") };
        interrupted = true;
      }
    });
    this.closeOpenToolUses();
    if (interrupted) this.persist();
  }

  /** Si se cortó a mitad de una acción, la API necesita su resultado antes del próximo mensaje. */
  private closeOpenToolUses() {
    const last = this.history[this.history.length - 1];
    if (!last || last.role !== "assistant" || !Array.isArray(last.content)) return;
    const ids = (last.content as Json[]).filter((b) => b.type === "tool_use" && typeof b.id === "string").map((b) => b.id as string);
    if (!ids.length) return;
    this.history.push({
      role: "user",
      content: ids.map((id) => ({ type: "tool_result", tool_use_id: id, content: "Interrupted by the user.", is_error: true })),
    });
  }

  /** Guarda la conversación (título = el primer mensaje) y actualiza la lista del historial. */
  private persist() {
    if (!this.robotID || !this.items.length) return;
    let first = "Conversation";
    for (const item of this.items) {
      if ("user" in item.kind) {
        first = item.kind.user._0;
        break;
      }
    }
    const chars = Array.from(first);
    const title = chars.length > 60 ? chars.slice(0, 57).join("") + "…" : first;
    const updatedAt = swiftDate.now();
    const id = this.conversationID;
    ChatQueries.save({
      id,
      robotID: this.robotID,
      title,
      updatedAt,
      items: this.items.map((i) => ({ id: i.id, kind: i.kind })),
      history: utf8Base64.encode(JSON.stringify(this.history)),
    }).catch(() => {});
    this.conversations = [{ id, title, updatedAt }, ...this.conversations.filter((c) => c.id !== id)];
  }

  private setKind(index: number, kind: ChatItemKind) {
    const item = this.items[index];
    if (item) this.items[index] = { ...item, kind };
  }

  // ---------- Bucle con herramientas ----------

  private async run(apiKey: string, baseSystem: string, signal: AbortSignal) {
    this.isRunning = true;
    try {
      // Las notas del robot (lo que mide la app, lo que escribió la persona y lo aprendido), leídas en cada
      // mensaje para que un cambio en la pestaña Notes ya cuente.
      const robotID = this.robotID;
      const [facts, notes] = await Promise.all([
        this.body.chatRobotFacts?.().catch(() => null) ?? Promise.resolve(null),
        RobotNotesQueries.load(robotID).catch(() => ({ notes: "", learned: [] })),
      ]);
      const system = baseSystem + RobotNotes.promptSection(facts ?? [], notes);
      for (let turn = 0; turn < MAX_TURNS; turn++) {
        if (signal.aborted) return;
        let response: Json;
        try {
          const body: Json = {
            model: this.settings.modelID,
            max_tokens: 16000,
            system,
            tools: [...this.body.chatTools, RobotNotes.rememberTool],
            output_config: { effort: this.settings.effort },
            // El prompt del sistema cambia entre turnos (estado del robot, cámaras, calibración): los
            // pensamientos de turnos anteriores quedan atados al prompt viejo y la API los rechazaría.
            // Con drop_block los descarta y la conversación sigue.
            thinking: { type: "adaptive", block_binding: { prefix_mismatch_behavior: "drop_block" } },
            messages: this.history,
          };
          // Si un filtro de seguridad declina, la API reintenta con otro modelo (solo Opus y Sonnet).
          if (!this.settings.modelID.includes("haiku")) body.fallbacks = "default";
          response = await AnthropicQueries.createMessage(apiKey, body, signal);
        } catch (e) {
          if (!signal.aborted) this.error = message(e);
          return;
        }
        if (signal.aborted) return;

        const content: Json[] = Array.isArray(response.content) ? response.content : [];
        this.history.push({ role: "assistant", content });
        for (const block of content) {
          if (block.type === "text" && typeof block.text === "string" && block.text) {
            this.items.push({ id: uuid(), kind: Item.assistant(block.text) });
          }
        }

        switch (response.stop_reason) {
          case "tool_use": {
            const results: Json[] = [];
            for (const block of content) {
              if (block.type !== "tool_use") continue;
              results.push(await this.execute(block, signal));
              if (signal.aborted) return;
            }
            this.history.push({ role: "user", content: results });
            break;
          }
          case "refusal":
            this.items.push({ id: uuid(), kind: Item.notice("The AI can't help with that request.", true) });
            return;
          case "max_tokens":
            this.items.push({ id: uuid(), kind: Item.notice("The reply was cut off for length.", false) });
            return;
          default:
            return;
        }
      }
      this.items.push({ id: uuid(), kind: Item.notice("Reached the maximum number of steps in a row. Ask it to continue.", false) });
    } finally {
      // Si se detuvo, stop() ya lo dejó quieto (y puede haber empezado otra vuelta).
      if (!signal.aborted) {
        this.isRunning = false;
        this.task = null;
      }
      this.persist();
    }
  }

  /**
   * Corre una herramienta y devuelve su tool_result. Muestra el avance en el chat y, si mueve un robot
   * real, antes espera la aprobación de la persona.
   */
  private async execute(block: Json, signal: AbortSignal): Promise<Json> {
    const id = typeof block.id === "string" ? block.id : "";
    const name = typeof block.name === "string" ? block.name : "";
    const input: Json = block.input && typeof block.input === "object" ? block.input : {};
    if (name === "remember") return this.remember(id, typeof input.note === "string" ? input.note : "");
    const title = this.body.chatTitle(name, input);

    const detail = this.body.chatApproval(name, input);
    if (detail != null) {
      this.items.push({ id: uuid(), kind: Item.approval(title, detail, "pending") });
      const index = this.items.length - 1;
      const ok = await new Promise<boolean>((resolve) => {
        this.answer(false); // por si quedaba otra esperando
        this.waitingApproval = resolve;
      });
      this.setKind(index, Item.approval(title, detail, ok ? "approved" : "rejected"));
      if (!ok) return result(id, "The user didn't approve this move. Ask them what they'd prefer.", true);
    }

    this.items.push({ id: uuid(), kind: Item.action(title, "", true, false) });
    const index = this.items.length - 1;
    const finish = (detail: string, failed = false) => {
      if (signal.aborted) return; // stop() ya la marcó como interrumpida
      this.setKind(index, Item.action(title, detail, false, failed));
    };

    try {
      const run = this.body.chatRun.bind(this.body) as RunWithSignal;
      const output = await run(name, input, signal);
      if (output.kind === "text") {
        finish(output.problem ?? "", output.problem != null);
        return result(id, output.text);
      }
      const content: Json[] = [];
      let photos;
      if (output.kind === "report") {
        finish(output.problem ?? "", output.problem != null);
        content.push({ type: "text", text: output.text });
        photos = output.photos;
      } else {
        finish("");
        photos = output.images;
      }
      for (const photo of photos) {
        if (!signal.aborted) this.items.push({ id: uuid(), kind: Item.image(photo.jpeg) });
        if (photo.label) content.push({ type: "text", text: `Camera "${photo.label}":` });
        content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: photo.jpeg } });
      }
      return { type: "tool_result", tool_use_id: id, content };
    } catch (e) {
      finish(message(e), true);
      return result(id, message(e), true);
    }
  }

  /** La IA guarda una lección en las notas de este robot (sin aprobación: no mueve nada). */
  private async remember(id: string, note: string): Promise<Json> {
    const robotID = this.robotID;
    this.items.push({ id: uuid(), kind: Item.action(`Noted: ${note.trim()}`, "", false, false) });
    try {
      const file = await RobotNotesQueries.load(robotID);
      const learned = RobotNotes.addLesson(file.learned, note);
      if (!learned) return result(id, "Already noted.");
      await RobotNotesQueries.save(robotID, { ...file, learned });
      return result(id, "Saved.");
    } catch (e) {
      return result(id, message(e), true);
    }
  }
}

function result(id: string, text: string, isError = false): Json {
  const r: Json = { type: "tool_result", tool_use_id: id, content: text };
  if (isError) r.is_error = true;
  return r;
}
