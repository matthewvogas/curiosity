import { Files, join } from "./native";
import { AppPaths } from "@/utils/app-paths";

/**
 * Las notas de cada tarea: un documento con formato, guardado como HTML en notes/<id>.html.
 * (La versión de macOS usaba RTF: si solo existe el .rtf, se muestra su texto plano.)
 */
export const NoteQueries = {
  path: (taskID: string) => join(AppPaths.notes, `${taskID}.html`),

  async load(taskID: string): Promise<string> {
    const html = await Files.readText(NoteQueries.path(taskID));
    if (html != null) return html;
    const rtf = await Files.readText(join(AppPaths.notes, `${taskID}.rtf`));
    return rtf ? rtfToHTML(rtf) : "";
  },

  save: (taskID: string, html: string) => Files.writeText(NoteQueries.path(taskID), html),
};

/** Lo justo para no perder el texto de una nota RTF vieja (sin formato). */
function rtfToHTML(rtf: string): string {
  const text = rtf
    .replace(/\\par[d]?/g, "\n")
    .replace(/\{\\\*?[^{}]*\}/g, "")
    .replace(/\\'([0-9a-f]{2})/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\[a-z]+-?\d* ?/gi, "")
    .replace(/[{}]/g, "")
    .trim();
  const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  return text.split("\n").map((l) => `<p>${esc(l) || "<br>"}</p>`).join("");
}
