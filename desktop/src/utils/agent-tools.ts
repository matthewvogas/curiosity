import { actuatedJoints, type JointInfo, type RobotModel, type SimulationState } from "@/types/robot-types";
import { Units } from "./units";

type Json = Record<string, any>;

/**
 * Las herramientas con las que la IA maneja el robot simulado, el prompt del sistema y el formato
 * del estado que se le devuelve. Solo datos y transformaciones: la ejecución está en use-chat.
 */
export const AgentTools = {
  // ---------- Herramientas ----------

  definitions: [
    tool(
      "get_state",
      "Reads what the robot feels: each joint (position, target, limits, force). It does NOT say where objects are: for that, look through a camera.",
      {},
      [],
    ),
    tool(
      "move_joints",
      "Sends targets to the joints and runs the simulation for a few seconds so the robot moves. Motors have limited force: if something blocks it, it won't reach the target. Returns the final state.",
      {
        targets: {
          type: "array",
          description: "Targets. Values in degrees for joints that rotate and in centimeters for joints that slide.",
          items: {
            type: "object",
            properties: {
              joint: { type: "string", description: "Exact joint name." },
              value: { type: "number", description: "Target in degrees or centimeters." },
            },
            required: ["joint", "value"],
            additionalProperties: false,
          },
        },
        seconds: { type: "number", description: "How long to run the simulation afterwards, in seconds (0.2 to 5). Default 1.5." },
      },
      ["targets", "seconds"],
    ),
    tool(
      "look",
      "Takes a picture through one of the robot's cameras. It comes with a pixel grid (labels every 64 px) and its size, so you can point at things for pick and place.",
      { camera: { type: "string", description: "Camera name (for example the fixed one over the table)." } },
      ["camera"],
    ),
    tool(
      "pick",
      "Picks up an object on its own, in real time: you point at it in a camera picture and the arm works out how to reach it, opens, goes down, closes and lifts. It returns whether the gripper is holding something (felt by the gripper, as on a real robot) and a new picture.",
      {
        camera: { type: "string", description: "The camera of the picture you're pointing in." },
        x: { type: "number", description: "Pixel x of the CENTER OF THE TOP of the object, in that picture." },
        y: { type: "number", description: "Pixel y of the center of the top of the object." },
        height_cm: { type: "number", description: "Your estimate of the object's height, in cm (e.g. 2.5 for a small cube)." },
      },
      ["camera", "x", "y", "height_cm"],
    ),
    tool(
      "place",
      "Puts down what the gripper is holding, on its own: you point at the spot in a camera picture; the arm goes there, lowers it, opens and goes back up. Returns a new picture.",
      {
        camera: { type: "string", description: "The camera of the picture you're pointing in." },
        x: { type: "number", description: "Pixel x of where it should go." },
        y: { type: "number", description: "Pixel y of where it should go." },
        height_cm: { type: "number", description: "Height of the object being held, in cm." },
        surface_cm: { type: "number", description: "Height of the surface it goes on: 0 for the table, or the height of the object it goes on top of." },
      },
      ["camera", "x", "y", "height_cm", "surface_cm"],
    ),
    tool("gripper", "Opens or closes the gripper and says whether it's holding something.", { open: { type: "boolean" } }, ["open"]),
    tool(
      "add_object",
      "Puts an object in the scene (it falls with gravity). Position in centimeters in the robot base frame (z up).",
      {
        shape: { type: "string", enum: ["box", "sphere", "cylinder"] },
        size_cm: { type: "array", items: { type: "number" }, description: "box: [length, width, height] · sphere: [radius] · cylinder: [radius, height]" },
        mass_g: { type: "number" },
        position_cm: { type: "array", items: { type: "number" }, description: "[x, y, z]" },
        color: { type: "string", description: "Hex color, for example #e4572e." },
      },
      ["shape", "size_cm", "mass_g", "position_cm", "color"],
    ),
    tool(
      "create_object",
      "Creates a real-world object from a description (a wheel, a desk, a kitchen knife, a mug…) with its real size and weight, built from simple parts, and drops it on a free spot of the table. Use it instead of add_object for anything that isn't a plain box, ball or cylinder.",
      { description: { type: "string", description: "What the object is, with any detail that matters (size, material, color)." } },
      ["description"],
    ),
    tool("remove_object", "Removes an object from the scene by its id.", { id: { type: "integer" } }, ["id"]),
    tool("reset", "Returns the robot to its starting pose, at rest. Doesn't move the objects.", {}, []),
  ] as Json[],

  // ---------- Prompt del sistema ----------

  systemPrompt(model: RobotModel, robotName: string): string {
    const joints = actuatedJoints(model)
      .map((j) => {
        const range =
          j.lower != null && j.upper != null ? `${Units.format(j.lower, j.type)} to ${Units.format(j.upper, j.type)}` : "no limit";
        return `- ${j.name} (${j.type === "prismatic" ? "slides" : "rotates"}, ${range}, max force ${j.fmax.toFixed(1)})`;
      })
      .join("\n");
    const cameras = model.cameras.length === 0 ? "none" : model.cameras.join(", ");
    return `You are the assistant in Curiosity, a robot simulator. You control a simulated robot with real \
physics (gravity, collisions, friction, force-limited motors) through tools. The user asks you \
for tasks in natural language; you turn them into movements.

Robot: ${robotName} (model "${model.name}"), ${model.links.length} parts, ${model.floating ? "free base (it can fall over)" : "fixed base"}.
Motorized joints (the only ones you can command):
${joints}${passive(model)}
Cameras: ${cameras}.

This works like a real robot: you don't know where objects are except by looking through a camera. \
You're the planner and the eyes; the arm has its own controller that does the movement in real time.

How to work:
- Look through the fixed camera over the table (look) to find things. Point in pixels, using the grid.
- To move objects use pick and place: you say what (a pixel) and the arm works out how. Each one \
returns a new picture: check it, and if it failed (missed, nothing in the gripper), point again more \
carefully and retry.
- Use move_joints only for things pick/place can't do (gestures, small adjustments).
- To add things to the scene, use create_object with a plain description; it builds them at real scale.
- The frame is the robot base frame: z up, in centimeters. Joints are commanded in degrees \
(or centimeters if they slide) and never outside their limits.
- This is a simulation: there's no physical risk, but explain in one sentence what you're going to do.
- Reply in the user's language, briefly and without unnecessary jargon.`;
  },

  // ---------- Estado para la IA ----------

  /** Estado legible por la IA, en grados y centímetros. */
  describe(state: SimulationState, model: RobotModel): Json {
    const info = new Map<string, JointInfo>(model.joints.map((j) => [j.name, j]));
    const joints = state.joints.map((s) => {
      const j = info.get(s.name);
      const type = j?.type ?? "revolute";
      const out: Json = {
        joint: s.name,
        position: round1(Units.toDisplay(s.q, type)),
        target: round1(Units.toDisplay(s.target, type)),
        unit: Units.symbol(type),
        force: round1(s.force),
      };
      if (j?.lower != null && j?.upper != null) {
        out.limits = [round1(Units.toDisplay(j.lower, type)), round1(Units.toDisplay(j.upper, type))];
      }
      return out;
    });
    // Como un robot real: solo lo que siente (sus articulaciones), no dónde están los objetos.
    return { time_s: round1(state.time), joints };
  },

  /** Una frase corta para mostrar en el chat lo que hace cada herramienta. */
  title(name: string, input: Json): string {
    const int = (v: unknown) => Math.trunc(Number(v) || 0);
    switch (name) {
      case "get_state":
        return "Reading the state";
      case "move_joints": {
        const targets = (Array.isArray(input.targets) ? input.targets : []).map(
          (t: Json) => `${t.joint ?? ""} → ${swiftNumber(round1(Number(t.value) || 0))}`,
        );
        return "Moving " + (targets.length === 0 ? "the robot" : targets.join(", "));
      }
      case "look": {
        const cam = typeof input.camera === "string" ? input.camera : "";
        return cam ? `Looking from "${cam}"` : "Looking at the scene";
      }
      case "add_object":
        return `Adding an object (${typeof input.shape === "string" ? input.shape : ""})`;
      case "create_object":
        return `Creating ${typeof input.description === "string" ? input.description : "an object"}`;
      case "remove_object":
        return `Removing object ${input.id ?? ""}`;
      case "reset":
        return "Returning to the starting pose";
      case "pick":
        return `Picking up what's at (${int(input.x)}, ${int(input.y)})`;
      case "place":
        return `Putting it down at (${int(input.x)}, ${int(input.y)})`;
      case "gripper":
        return input.open === false ? "Closing the gripper" : "Opening the gripper";
      default:
        return name;
    }
  },

  /** JSON con las claves ordenadas (como JSONSerialization con .sortedKeys). */
  json(value: unknown): string {
    try {
      return JSON.stringify(sortKeys(value)) ?? "{}";
    } catch {
      return "{}";
    }
  },
};

function tool(name: string, description: string, properties: Json, required: string[]): Json {
  return {
    name,
    description,
    strict: true,
    input_schema: { type: "object", properties, required, additionalProperties: false },
  };
}

function passive(model: RobotModel): string {
  const rest = model.joints.filter((j) => !j.actuated);
  if (rest.length === 0) return "";
  const list = rest.map((j) => (j.mimic ? `${j.name} (follows ${j.mimic})` : `${j.name} (no motor)`));
  return "\nMove on their own: " + list.join(", ") + ".";
}

/** Redondeo a un decimal, con los medios lejos de cero (como `rounded()` de Swift). */
function round1(v: number): number {
  return (Math.sign(v) * Math.round(Math.abs(v) * 10)) / 10 || 0;
}

/** Un Double como lo escribe Swift al interpolarlo («45.0», «-12.5»). */
function swiftNumber(v: number): string {
  return Number.isInteger(v) ? v.toFixed(1) : String(v);
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") {
    const out: Json = {};
    for (const k of Object.keys(v).sort()) out[k] = sortKeys((v as Json)[k]);
    return out;
  }
  return v;
}
