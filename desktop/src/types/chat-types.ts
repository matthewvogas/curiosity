import type { SwiftDate } from "@/utils/codable";

/**
 * Un renglón de la conversación tal como se muestra (la historia para la API va aparte).
 * `kind` tiene la forma con que Swift guardaba los enums con valores asociados, para leer los chats viejos:
 *   { user: { _0: "texto" } } · { image: { _0: "<jpeg base64>" } } · { notice: { _0: "…", isError } } …
 */
export type ChatItemKind =
  | { user: { _0: string } }
  | { assistant: { _0: string } }
  /** Una acción de la IA sobre el robot. */
  | { action: { title: string; detail: string; running: boolean; failed: boolean } }
  /** Lo que la IA miró (JPEG en base64). */
  | { image: { _0: string } }
  | { notice: { _0: string; isError: boolean } }
  /** Un movimiento del robot real que la persona debe aprobar antes de que ocurra. */
  | { approval: { title: string; detail: string; state: ApprovalState } };

export type ApprovalState = "pending" | "approved" | "rejected";

export type ChatItem = { id: string; kind: ChatItemKind };

/** Atajos para crear y leer renglones sin pelear con la forma de arriba. */
export const Item = {
  user: (text: string): ChatItemKind => ({ user: { _0: text } }),
  assistant: (text: string): ChatItemKind => ({ assistant: { _0: text } }),
  action: (title: string, detail: string, running = true, failed = false): ChatItemKind => ({ action: { title, detail, running, failed } }),
  image: (jpeg: string): ChatItemKind => ({ image: { _0: jpeg } }),
  notice: (text: string, isError = false): ChatItemKind => ({ notice: { _0: text, isError } }),
  approval: (title: string, detail: string, state: ApprovalState = "pending"): ChatItemKind => ({ approval: { title, detail, state } }),
};

/** Una foto con su nombre (la cámara de donde sale; vacío si hay una sola). JPEG en base64. */
export type Photo = { label: string; jpeg: string };

/** Lo que devuelve una herramienta: texto para la IA (y un aviso si algo no salió), fotos, o las dos. */
export type ChatToolOutput =
  | { kind: "text"; text: string; problem?: string }
  | { kind: "images"; images: Photo[] }
  /** Texto y fotos juntos (p. ej. cómo terminó una orden y cómo quedó la mesa), en una sola vuelta. */
  | { kind: "report"; text: string; photos: Photo[]; problem?: string };

/** Con qué habla la IA: el robot simulado o el real. Da las herramientas, el prompt y las corre. */
export interface ChatBody {
  readonly chatTools: Record<string, unknown>[];
  /** null mientras el robot no está listo para conversar (cargando, desconectado…). */
  chatSystemPrompt(robotName: string): string | null;
  readonly chatNotReady: string;
  chatTitle(name: string, input: Record<string, any>): string;
  /** Lo que la persona tiene que aprobar antes de correr la herramienta (null: no hace falta). */
  chatApproval(name: string, input: Record<string, any>): string | null;
  chatRun(name: string, input: Record<string, any>): Promise<ChatToolOutput>;
  /** Lo que la app mide del robot (brazo, pinza, cámaras), una línea por dato, para las notas del robot. */
  chatRobotFacts?(): Promise<string[] | null>;
}

/** Una conversación guardada con un robot: lo que se ve y la historia para seguirla con la API. */
export type Conversation = {
  id: string;
  robotID: string;
  title: string;
  updatedAt: SwiftDate;
  items: ChatItem[];
  /** Mensajes en el formato de la API: JSON en base64 (como el Data de Swift). Ver utf8Base64. */
  history: string;
};

/** Para la lista del historial (sin cargar los mensajes). */
export type ConversationSummary = { id: string; title: string; updatedAt: SwiftDate };

/** Modelos de IA disponibles para conversar con el robot. */
export type AIModel = { id: string; name: string; detail: string };

export const AI_MODELS: AIModel[] = [
  { id: "claude-opus-5-5", name: "Claude Opus 5.5", detail: "Most capable for planning tasks" },
  { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", detail: "Fast and capable" },
  { id: "claude-haiku-5-5", name: "Claude Haiku 5.5", detail: "Fastest and cheapest" },
];
