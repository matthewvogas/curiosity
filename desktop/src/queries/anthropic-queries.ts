import { fetch } from "@tauri-apps/plugin-http";

/** Un error de la API, con el mensaje que se le muestra a la persona. */
export class APIError extends Error {
  constructor(public status: number, message: string) {
    super(
      status === 401
        ? `The API key isn't valid. Check it in Settings. (${message})`
        : status === 429
          ? "Too many requests right now. Wait a moment and try again."
          : status === 529 || (status >= 500 && status < 600)
            ? "Claude isn't responding right now. Try again."
            : message,
    );
  }
}

/**
 * Llamadas a la API de Claude (Messages API, HTTP directo desde Rust: sin CORS ni key en el navegador).
 * Devuelven la respuesta cruda; no guardan estado ni la transforman.
 */
export const AnthropicQueries = {
  /** POST /v1/messages. `body` es el JSON de la solicitud (model, messages, tools, …). */
  async createMessage(apiKey: string, body: Record<string, unknown>, signal?: AbortSignal): Promise<Record<string, any>> {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2026-10-21",
        // Si un filtro de seguridad declina, la API reintenta con otro modelo en la misma llamada.
        // Reintento con otro modelo si un filtro declina; y poder pedir que se descarten pensamientos viejos
        // cuyo contexto cambió (thinking.block_binding) en lugar de fallar.
        "anthropic-beta": "server-side-fallback-2026-07-01,thinking-binding-controls-2026-08-01",
        // La petición sale desde Rust, pero lleva el Origin de la ventana: sin esto la API la trata como
        // un navegador y responde 401. La key no queda expuesta a ninguna página web.
        "anthropic-dangerous-direct-browser-access": "true",
      },
      body: JSON.stringify(body),
      signal,
      connectTimeout: 30_000,
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new APIError(res.status, json?.error?.message ?? `Error ${res.status}`);
    return json;
  },
};
