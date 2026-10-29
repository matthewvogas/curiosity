import type { ObjectPart, SceneObject } from "@/types/robot-types";

type Json = Record<string, any>;

/**
 * Objetos de la escena diseñados por la IA a partir de una descripción («una rueda de bicicleta», «un
 * escritorio», «un cuchillo de cocina»): piezas simples con medidas y peso del mundo real. La IA responde
 * con la herramienta `build_object` (se le pide que la use: los modelos actuales no aceptan forzarla), así que la
 * respuesta es JSON válido.
 */
export const ObjectDesigner = {
  system: `You design physical objects for a robot physics simulator (MuJoCo). Given a short description, \
build the object from simple primitive parts with REAL-WORLD dimensions and mass, then call build_object.

Rules:
- Units: centimeters, degrees, kilograms. The object's frame: origin at the center of the whole object, z up, \
x forward, y left. Part positions are relative to that origin.
- Shapes: box [length x, width y, height z] · sphere [radius] · cylinder [radius, length] · capsule [radius, \
length of the straight part]. Cylinders and capsules point along z; rotate them with rotation_deg (e.g. [90, 0, 0] \
makes the axis horizontal along y, like a wheel standing up; [0, 90, 0] lays it along x).
- Use real sizes for a typical example of the thing (a kitchen knife ≈ 30 cm long, blade 3 cm tall and 0.2 cm \
thick; a desk ≈ 120 × 60 cm top at 75 cm high; a bicycle wheel ≈ 66 cm diameter). Do not scale things down to \
robot size: the scene is real scale.
- Mass: what the real object weighs (steel ≈ 7.8 g/cm³, wood ≈ 0.6, plastic ≈ 1.1, rubber ≈ 1.2), as the total.
- Use as few parts as needed for the shape to read clearly and to behave right physically: 1 for simple things, \
up to 16 for complex ones. Parts may overlap. Keep thin parts at least 0.2 cm thick.
- The object rests in its natural orientation (a desk on its legs, a mug upright, a knife lying flat).
- Colors: realistic hex colors per part (metal grays, wood browns, black rubber…).`,

  tool: {
    name: "build_object",
    description: "Builds the object from primitive parts, in real-world units.",
    input_schema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Short name, e.g. 'Kitchen knife'." },
        mass_kg: { type: "number", description: "Total real-world mass." },
        parts: {
          type: "array",
          items: {
            type: "object",
            properties: {
              shape: { type: "string", enum: ["box", "sphere", "cylinder", "capsule"] },
              size_cm: { type: "array", items: { type: "number" } },
              position_cm: { type: "array", items: { type: "number" }, description: "[x, y, z] from the object's center" },
              rotation_deg: { type: "array", items: { type: "number" }, description: "[x, y, z], default [0, 0, 0]" },
              color: { type: "string", description: "Hex color, e.g. #8b6b4a" },
            },
            required: ["shape", "size_cm", "position_cm", "color"],
          },
        },
      },
      required: ["name", "mass_kg", "parts"],
    },
  },

  /** El cuerpo de la solicitud a la API para una descripción. */
  request(description: string, model: string): Json {
    return {
      model,
      max_tokens: 16000,
      system: `${ObjectDesigner.system}\n\nAnswer only by calling build_object, exactly once.`,
      tools: [ObjectDesigner.tool],
      // Los modelos actuales (Opus 5.5, Sonnet 5.5, Fable 5.1) no aceptan forzar la herramienta: se le pide.
      tool_choice: { type: "auto" },
      messages: [{ role: "user", content: description }],
    };
  },

  /** La respuesta de la API → un objeto listo para soltar en la escena (o un error que se pueda leer). */
  parse(response: Json): SceneObject {
    const use = (Array.isArray(response.content) ? response.content : []).find((b: Json) => b?.type === "tool_use");
    const input: Json = use?.input ?? {};
    const parts: ObjectPart[] = (Array.isArray(input.parts) ? input.parts : [])
      .map((p: Json): ObjectPart | null => {
        const size = numbers(p.size_cm);
        if (!size?.length) return null;
        const shape = ["box", "sphere", "cylinder", "capsule"].includes(p.shape) ? p.shape : "box";
        return {
          shape,
          size: size.map((v) => Math.max(v, 0.2) / 100),
          pos: (numbers(p.position_cm) ?? [0, 0, 0]).slice(0, 3).map((v) => v / 100),
          euler: (numbers(p.rotation_deg) ?? [0, 0, 0]).slice(0, 3),
          color: typeof p.color === "string" && /^#[0-9a-f]{6}$/i.test(p.color) ? p.color : "#9a9a9f",
        };
      })
      .filter((p: ObjectPart | null): p is ObjectPart => p !== null)
      .slice(0, 24);
    if (parts.length === 0) throw new Error("The AI didn't return a usable object. Try describing it differently.");
    const mass = Number(input.mass_kg);
    return {
      id: 0,
      shape: parts[0].shape,
      size: parts[0].size,
      mass: Number.isFinite(mass) && mass > 0 ? Math.min(mass, 500) : 1,
      color: parts[0].color,
      pos: [0, 0, 0],
      yaw: 0,
      fixed: false,
      name: typeof input.name === "string" ? input.name.slice(0, 40) : "Object",
      parts,
      drop: true,
    };
  },
};

function numbers(v: unknown): number[] | null {
  if (!Array.isArray(v)) return null;
  const out = v.map(Number);
  return out.every(Number.isFinite) ? out : null;
}
