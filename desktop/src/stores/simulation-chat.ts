import type { RobotModel, SceneObject } from "@/types/robot-types";
import type { ChatToolOutput, Photo } from "@/types/chat-types";
import { AgentTools } from "@/utils/agent-tools";
import { Units } from "@/utils/units";
import type { UseSimulation } from "./use-simulation";

type Json = Record<string, any>;

const PHOTO_WIDTH = 768;

const numberOr = (v: unknown, fallback: number) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);

/**
 * La simulación como cuerpo del chat (el `extension UseSimulation: ChatBody` de Swift): las herramientas de
 * AgentTools corridas sobre el motor. UseSimulation implementa ChatBody llamando a estas funciones.
 */
export const SimulationChat = {
  tools: AgentTools.definitions,
  notReady: "Wait for the robot to finish loading.",

  systemPrompt(sim: UseSimulation, robotName: string): string | null {
    return sim.model ? AgentTools.systemPrompt(sim.model, robotName) : null;
  },

  title(name: string, input: Json): string {
    return AgentTools.title(name, input);
  },

  async run(sim: UseSimulation, name: string, input: Json, signal?: AbortSignal): Promise<ChatToolOutput> {
    const model = sim.model;
    if (!model) throw new Error(SimulationChat.notReady);
    const unknownCamera = (): ChatToolOutput => ({
      kind: "text",
      text: `There's no camera with that name. Cameras: ${model.cameras.join(", ")}.`,
      problem: "Unknown camera",
    });

    switch (name) {
      case "get_state":
        return { kind: "text", text: AgentTools.json(chatState(sim, model)) };

      case "move_joints": {
        const types = new Map(model.joints.map((j) => [j.name, j]));
        const unknown: string[] = [];
        for (const t of Array.isArray(input.targets) ? (input.targets as Json[]) : []) {
          const joint = t?.joint;
          const value = t?.value;
          if (typeof joint !== "string" || typeof value !== "number") continue;
          const info = types.get(joint);
          if (!info || !info.actuated) {
            unknown.push(joint);
            continue;
          }
          let v = Units.fromDisplay(value, info.type);
          if (info.lower != null && info.upper != null) v = Math.min(info.upper, Math.max(info.lower, v));
          sim.setTarget(joint, v);
        }
        const seconds = Math.min(5, Math.max(0.2, numberOr(input.seconds, 1.5)));
        await sim.run(seconds, signal);
        const out = chatState(sim, model);
        if (unknown.length) out.unknown_joints = unknown;
        return {
          kind: "text",
          text: AgentTools.json(out),
          problem: unknown.length ? `No motor or doesn't exist: ${unknown.join(", ")}` : undefined,
        };
      }

      case "look": {
        const camera = typeof input.camera === "string" && model.cameras.includes(input.camera) ? input.camera : null;
        if (!camera) return unknownCamera();
        return { kind: "images", images: [await photo(sim, camera)] };
      }

      case "pick":
      case "place":
      case "gripper": {
        const spec: Json = { type: name };
        if (name === "gripper") {
          spec.open = typeof input.open === "boolean" ? input.open : true;
        } else {
          const camera = input.camera;
          if (typeof camera !== "string" || !model.cameras.includes(camera)) return unknownCamera();
          spec.camera = camera;
          spec.x = input.x ?? 0;
          spec.y = input.y ?? 0;
          spec.width = PHOTO_WIDTH;
          spec.height = numberOr(input.height_cm, 2.5) / 100;
          spec.surface = numberOr(input.surface_cm, 0) / 100;
        }
        const outcome = await sim.skill(spec, signal);
        const out: Json = { ...outcome, joints: chatState(sim, model).joints };
        // Una foto de la misma cámara para que vea cómo quedó (la fija de la mesa si fue solo la pinza).
        const cameras = sim.model?.cameras ?? model.cameras;
        const camera =
          (typeof input.camera === "string" && cameras.includes(input.camera) ? input.camera : null) ?? cameras[cameras.length - 1] ?? null;
        const picture: Photo[] = [];
        if (camera) picture.push(await photo(sim, camera));
        const failed = outcome?.done === false;
        return {
          kind: "report",
          text: AgentTools.json(out),
          photos: picture,
          problem: failed ? (outcome.message ?? outcome.reason ?? undefined) : undefined,
        };
      }

      case "add_object": {
        const size = Units.meters((Array.isArray(input.size_cm) ? input.size_cm : []).map(Number));
        const pos = Units.meters((Array.isArray(input.position_cm) ? input.position_cm : []).map(Number));
        const object: SceneObject = {
          id: 0,
          shape: typeof input.shape === "string" ? input.shape : "box",
          size: size.length ? size : [0.03, 0.03, 0.03],
          mass: numberOr(input.mass_g, 20) / 1000,
          color: typeof input.color === "string" ? input.color : "#cccccc",
          pos: pos.length === 3 ? pos : [0.2, 0, 0.1],
          yaw: 0,
          fixed: false,
          name: "",
        };
        const newID = await sim.addObject(object);
        return { kind: "text", text: AgentTools.json({ id: newID }) };
      }

      case "create_object": {
        const { id, object } = await sim.designObject(typeof input.description === "string" ? input.description : "");
        const [w, d, h] = sizeCM(object);
        return { kind: "text", text: AgentTools.json({ id, name: object.name, size_cm: [w, d, h], mass_kg: object.mass }) };
      }

      case "remove_object":
        sim.removeObject(typeof input.id === "number" ? Math.trunc(input.id) : -1);
        return { kind: "text", text: "ok" };

      case "reset":
        sim.reset();
        await sim.run(0.3, signal);
        return { kind: "text", text: AgentTools.json(chatState(sim, model)) };

      default:
        return { kind: "text", text: `Unknown tool: ${name}`, problem: "Unknown tool" };
    }
  },
};

/** Lo que mide el objeto (largo, ancho, alto en cm), aproximado por sus piezas. */
function sizeCM(o: SceneObject): number[] {
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (const p of o.parts ?? []) {
    const r = Math.max(...p.size) / 2;
    for (let i = 0; i < 3; i++) {
      lo[i] = Math.min(lo[i], p.pos[i] - r);
      hi[i] = Math.max(hi[i], p.pos[i] + r);
    }
  }
  return lo.map((v, i) => (Number.isFinite(v) ? Math.round((hi[i] - v) * 1000) / 10 : 0));
}

function chatState(sim: UseSimulation, model: RobotModel): Json {
  return AgentTools.describe(sim.state, model);
}

/** Una foto de una cámara con la cuadrícula de píxeles y su tamaño, para poder señalar. */
async function photo(sim: UseSimulation, camera: string): Promise<Photo> {
  const size = await sim.cameraSize(camera);
  return { label: `${camera} (${size.width}×${size.height} px)`, jpeg: await sim.capture(camera, true) };
}
