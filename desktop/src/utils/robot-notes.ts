/**
 * Las notas de cada robot (como un CLAUDE.md, pero de un robot): lo que la app mide de él, lo que escribe la persona
 * y lo que la IA aprende. Un .md por conversación de robot (simulador y real por separado: son mesas distintas).
 * Solo transformaciones puras: el archivo lo leen y escriben las queries.
 */

type Json = Record<string, any>;

const LEARNED = "## Learned";
const MAX_LESSONS = 15;
const MAX_NOTES = 6000;

export type RobotNotesFile = { notes: string; learned: string[] };

/** Una cámara para describirla: fija o montada en una pieza; en el robot real, si está calibrada. */
export type FactCamera = { name: string; fixed?: boolean; link?: string; calibratedErrorPx?: number | null; live?: boolean };

export const RobotNotes = {
  /** El nombre del archivo: el robotID del chat sin caracteres raros. */
  fileName(robotID: string): string {
    return `${robotID.replace(/[^A-Za-z0-9._-]/g, "_")}.md`;
  },

  /** El texto del archivo → notas de la persona y lecciones (lo que va después del último «## Learned»). */
  parse(text: string | null): RobotNotesFile {
    if (!text) return { notes: "", learned: [] };
    const lines = text.split(/\r?\n/);
    let cut = -1;
    lines.forEach((l, i) => {
      if (l.trim() === LEARNED) cut = i;
    });
    if (cut < 0) return { notes: text.trim(), learned: [] };
    const learned = lines
      .slice(cut + 1)
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2).trim())
      .filter(Boolean);
    return { notes: lines.slice(0, cut).join("\n").trim(), learned };
  },

  format({ notes, learned }: RobotNotesFile): string {
    const body = notes.trim();
    if (!learned.length) return body ? `${body}\n` : "";
    return `${body}\n\n${LEARNED}\n${learned.map((l) => `- ${l}\n`).join("")}`;
  },

  /** Agrega una lección (sin repetir y con las últimas 15). null si ya estaba o está vacía. */
  addLesson(learned: string[], note: string): string[] | null {
    const n = note.trim().replace(/\s*\n\s*/g, " ");
    if (!n || learned.some((l) => l.toLowerCase() === n.toLowerCase())) return null;
    return [...learned, n].slice(-MAX_LESSONS);
  },

  /** Lo que la app sabe del robot, una línea por dato (ver studio.effector()). */
  factsLines(effector: Json | null, cameras: FactCamera[]): string[] {
    const out: string[] = [];
    const e = effector;
    if (e && Array.isArray(e.arm) && e.arm.length) {
      const reach = typeof e.reach_cm === "number" ? `; reach ≈ ${e.reach_cm} cm` : "";
      out.push(`- Arm: ${e.arm.length} motorized joints up to the tool (${e.arm.join(", ")})${reach}.`);
      if (e.gripper) {
        const kind = e.one_jaw ? "one moving jaw against a fixed one" : `${e.fingers} moving fingers`;
        const opens = typeof e.max_opening_cm === "number" ? `, opens up to ≈ ${e.max_opening_cm} cm` : "";
        out.push(`- Gripper: ${kind} (${e.gripper})${opens}; picks from above${e.can_turn ? " and turns to match the object" : ""}.`);
      } else {
        out.push("- No gripper recognized: pick and place won't work.");
      }
    }
    if (cameras.length) {
      const desc = cameras.map((c) => {
        if (c.live) {
          return c.calibratedErrorPx != null
            ? `${c.name} (calibrated, error ${c.calibratedErrorPx.toFixed(1)} px)`
            : `${c.name} (not calibrated: look only)`;
        }
        return c.fixed ? `${c.name} (fixed)` : `${c.name} (on ${c.link ?? "the robot"})`;
      });
      out.push(`- Cameras: ${desc.join(", ")}.`);
    }
    return out;
  },

  /** Lo que se agrega al final del prompt del sistema. */
  promptSection(facts: string[], { notes, learned }: RobotNotesFile): string {
    let out = "\n\n# About this robot";
    if (facts.length) out += `\nMeasured by the app:\n${facts.join("\n")}`;
    const n = notes.trim();
    if (n) out += `\n\nNotes from the user (follow them):\n${n.length > MAX_NOTES ? `${n.slice(0, MAX_NOTES)}\n…(cut)` : n}`;
    if (learned.length) out += `\n\nLearned in earlier sessions:\n${learned.map((l) => `- ${l}`).join("\n")}`;
    out +=
      "\n\nWhen you learn something lasting about this robot, its table or its objects (not a one-off result), save it with remember, in one short line. Don't repeat what's already here.";
    return out;
  },

  rememberTool: {
    name: "remember",
    description:
      "Saves one short lesson about this robot, its table or its objects, for future conversations (e.g. 'Jenga blocks slip if gripped along the long side'). Only lasting facts, not one-off results.",
    strict: true,
    input_schema: {
      type: "object",
      properties: { note: { type: "string" } },
      required: ["note"],
      additionalProperties: false,
    },
  } as Json,
};
