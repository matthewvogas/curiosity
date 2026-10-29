import { basename } from "@/queries/native";
import type { SkillModel } from "@/types/lerobot-types";
import { JointUnits } from "./joint-units";

type Json = Record<string, any>;
export type JointLimits = Record<string, [number, number]>;

function tool(name: string, description: string, properties: Json, required: string[]): Json {
  return {
    name,
    description,
    strict: true,
    input_schema: { type: "object", properties, required, additionalProperties: false },
  };
}

const round1 = (v: number) => Math.round(v * 10) / 10;
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/**
 * Las herramientas con las que la IA maneja el robot real, su prompt y cómo se describe cada acción. Solo datos y
 * transformaciones: la ejecución está en use-live-robot.
 */
export const RealAgentTools = {
  /** Las articulaciones del robot conectado, en orden, su unidad («deg», «0-100», «±100») y su tipo en LeRobot.
   *  Las pone la sesión en vivo con lo que dice LeRobot; nada de aquí supone un robot en particular. */
  joints: [] as string[],
  units: {} as Record<string, string>,
  robotType: "",

  get definitions(): Json[] {
    return [
      tool("get_state",
        "Reads where each joint of the real robot is, where it's heading and its allowed range. Use it before planning a move.",
        {}, []),
      tool("move_joints",
        "Moves the real robot toward these targets, slowly (about 40° per second for joints in degrees). The user has to approve each move before it happens. Returns the state on arrival.",
        {
          targets: {
            type: "array",
            description: "Targets, each in its joint's unit (see get_state).",
            items: {
              type: "object",
              properties: {
                joint: { type: "string", enum: RealAgentTools.joints },
                value: { type: "number" },
              },
              required: ["joint", "value"],
              additionalProperties: false,
            },
          },
        }, ["targets"]),
      tool("look", "Takes a picture with each robot camera (the main one and any others) to see the table, the arm and the objects.", {}, []),
      tool("go_home", "Slowly returns to the pose the robot was in when it was connected. Also requires approval.", {}, []),
    ];
  },

  /** Mandarle una orden en palabras al modelo de órdenes (SmolVLA, π0…), que la hace solo a 30 Hz. */
  runSkill: tool(
    "run_skill",
    "Gives a short instruction to the robot's own action model, which carries it out on its own in real time (30 times per second) and is much faster than move_joints. Use it for whole sub-tasks. The user approves it first. When it ends you get how it ended, the state and a picture from each camera.",
    {
      instruction: { type: "string", description: "One short, concrete action in English, like the ones the model was trained on. E.g. \"pick up the red cube and place it in the box\"." },
      seconds: { type: "number", description: "Maximum time it may take, 3 to 60 seconds." },
    },
    ["instruction", "seconds"],
  ),

  /** Lo que se agrega al prompt cuando hay un modelo de órdenes cargado. */
  skillSection(model: SkillModel): string {
    return (
      "\n\n" +
      `You also have an action model on the robot (${model.type}, ${basename(model.path)}). ` +
      "Work as a planner: split the user's request into short sub-tasks and give each one to run_skill; " +
      "it does the movement much faster than you can with move_joints. After each run_skill, look at the " +
      "pictures it returns and decide the next step (retry, correct with small move_joints, or move on). " +
      "Use move_joints only for small fixes or when the model can't do something."
    );
  },

  clampSkillSeconds(input: Json): number {
    return Math.min(60, Math.max(3, num(input.seconds) ?? 15));
  },

  lookReferences: tool(
    "look_references", "Shows the key-moment pictures from the demonstrations you studied, to compare with what you see.", {}, []),

  /** Las habilidades del brazo: la IA señala en una foto y el brazo hace el movimiento entero solo. */
  armTools: [
    tool("pick",
      "Picks up an object in ONE continuous move: you point at it in a picture from a calibrated camera; the arm works out the whole motion (open, approach, go down, close, lift) with its own kinematics and the user approves it once. Returns whether the gripper is holding something (felt by the gripper) and new pictures.",
      {
        camera: { type: "string", description: "Name of the calibrated camera whose picture you're pointing in." },
        x: { type: "number", description: "Pixel x of the CENTER OF THE TOP of the object, in that picture." },
        y: { type: "number", description: "Pixel y of the center of the top of the object." },
        height_cm: { type: "number", description: "Your estimate of the object's height, in cm." },
      }, ["camera", "x", "y", "height_cm"]),
    tool("place",
      "Puts down what the gripper holds, in ONE continuous move: you point at the spot in a calibrated camera's picture. Returns new pictures.",
      {
        camera: { type: "string", description: "Name of the calibrated camera whose picture you're pointing in." },
        x: { type: "number", description: "Pixel x of where it should go." },
        y: { type: "number", description: "Pixel y of where it should go." },
        height_cm: { type: "number", description: "Height of the object being held, in cm." },
        surface_cm: { type: "number", description: "Height of the surface it goes on: 0 for the table, or the height of the object it goes on top of." },
      }, ["camera", "x", "y", "height_cm", "surface_cm"]),
    tool("gripper", "Opens or closes the gripper and says whether it's holding something.",
      { open: { type: "boolean" } }, ["open"]),
  ] as Json[],

  systemPrompt(robotName: string, limits: JointLimits, calibratedCameras: string[]): string {
    const ranges = RealAgentTools.joints
      .filter((j) => limits[j])
      .map((j) => `- ${j}: ${RealAgentTools.format(limits[j][0], j)} to ${RealAgentTools.format(limits[j][1], j)}`)
      .join("\n");
    const cameras = calibratedCameras.length === 0
      ? "None of the cameras is calibrated yet, so pick and place can't locate things. Tell the user to calibrate the camera in the Arm tab (about a minute) before anything else."
      : `Calibrated cameras (you can point in their pictures): ${calibratedCameras.join(", ")}.`;
    return `You are the assistant in Curiosity and you control a REAL robot (LeRobot type ${RealAgentTools.robotType}) named ${robotName}, on a table, seen by one or more cameras.

How this works: you are the eyes and the planner; the arm has its own controller. You look, decide WHAT to do and point at it in a picture (pixels, using the grid on the picture). pick and place then do the whole movement on their own in one go, with the robot's kinematics and the limits of its calibration. The user approves each action once.
${cameras}

The robot's joints and their range, from its calibration (° is degrees; other joints use that motor's 0–100 or −100–100 scale; a gripper at 0 is closed):
${ranges}

Rules:
- Start by looking (look). Find the objects in the calibrated camera's picture and point at them.
- Split the request into actions (pick this, place it there) and use pick/place for each. After each one, check the pictures it returns; if it missed or isn't holding anything, point more carefully and retry.
- Don't move joint by joint to reach things: that's what pick/place are for. Use move_joints only for small adjustments or gestures, never to approach objects.
- Explain in one short sentence what you're about to do. Reply in the user's language, briefly.`;
  },

  /** Estado legible por la IA. */
  describe(current: Record<string, number>, targets: Record<string, number>, limits: JointLimits): Json {
    return {
      joints: RealAgentTools.joints.map((j) => {
        const unit = RealAgentTools.units[j];
        const out: Json = { joint: j, position: round1(current[j] ?? 0), target: round1(targets[j] ?? 0), unit: unit === "deg" ? "°" : unit ?? "" };
        const l = limits[j];
        if (l) {
          const q = current[j] ?? 0, span = l[1] - l[0];
          out.min = round1(l[0]);
          out.max = round1(l[1]);
          // Cuánta libertad le queda hacia cada lado y en qué parte de su recorrido está (0 % = mínimo).
          out.room_to_min = round1(q - l[0]);
          out.room_to_max = round1(l[1] - q);
          out.percent_of_range = span > 0 ? Math.round(((q - l[0]) / span) * 100) : 0;
        }
        return out;
      }),
    };
  },

  /** Un movimiento resumido: lo pedido, dónde estaba, dónde quedó, cuánto cambió cada articulación,
   *  si llegó, y cuánto se desplazó la pinza en el espacio. */
  move(asked: Record<string, number>, start: Record<string, number>, end: Record<string, number>, before: unknown, after: unknown): Json {
    const keys = Object.keys(asked);
    const pick = (src: Record<string, number>) =>
      Object.fromEntries(Object.entries(src).filter(([k]) => asked[k] != null).map(([k, v]) => [k, round1(v)]));
    const out: Json = {
      asked: Object.fromEntries(keys.map((k) => [k, round1(asked[k])])),
      before: pick(start),
      after: pick(end),
      change: Object.fromEntries(keys.map((k) => [k, round1((end[k] ?? 0) - (start[k] ?? 0))])),
      reached: Object.fromEntries(keys.map((k) => [k, Math.abs((end[k] ?? 0) - asked[k]) < 3])),
    };
    if (Array.isArray(before) && Array.isArray(after) && before.length === 3 && after.length === 3) {
      out.gripper_before_cm = before;
      out.gripper_after_cm = after;
      out.gripper_moved_cm = after.map((a: number, i: number) => round1(a - before[i]));
    }
    return out;
  },

  /** Lo que se le muestra a la persona para aprobar: el comando exacto. */
  approval(name: string, input: Json, current: Record<string, number>): string | null {
    switch (name) {
      case "move_joints":
        return ((input.targets as Json[]) ?? [])
          .flatMap((t) => {
            const v = num(t.value);
            if (typeof t.joint !== "string" || v == null) return [];
            return [`${t.joint}: ${RealAgentTools.format(current[t.joint] ?? 0, t.joint)} → ${RealAgentTools.format(v, t.joint)}`];
          })
          .join("\n");
      case "go_home":
        return "All joints to the starting pose.";
      case "run_skill":
        return `The action model moves the robot on its own for up to ${Math.trunc(RealAgentTools.clampSkillSeconds(input))} s:\n«${input.instruction ?? ""}»`;
      default:
        return null;
    }
  },

  title(name: string): string {
    switch (name) {
      case "get_state": return "Reading the state";
      case "move_joints": return "Move the robot";
      case "look": return "Looking through the camera";
      case "go_home": return "Return to the starting pose";
      case "run_skill": return "Action model";
      default: return name;
    }
  },

  format(v: number, joint: string): string {
    return JointUnits.format(v, RealAgentTools.units[joint]);
  },
};
