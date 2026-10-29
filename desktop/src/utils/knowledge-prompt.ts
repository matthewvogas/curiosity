import type { KnowledgePackage, StudyMaterial } from "@/types/knowledge-types";
import { jointOrder } from "@/types/knowledge-types";
import { swiftDate, uuid } from "./codable";
import { RealAgentTools } from "./real-agent-tools";

type Json = Record<string, any>;

/** Un Double como lo escribe Swift al interpolarlo («2.0», «1.5»). */
export const swiftNumber = (v: number) => (Number.isInteger(v) ? v.toFixed(1) : String(v));

function object(fields: Record<string, string>): Json {
  return {
    type: "object",
    additionalProperties: false,
    required: Object.keys(fields),
    properties: Object.fromEntries(Object.entries(fields).map(([k, t]) => [k, { type: t }])),
  };
}

function offsets(): Json {
  return {
    type: "array",
    description: "Adjustments to add to each point, in each joint's unit. Empty if not needed.",
    items: {
      type: "object",
      additionalProperties: false,
      required: ["joint", "delta"],
      properties: { joint: { type: "string", enum: RealAgentTools.joints }, delta: { type: "number" } },
    },
  };
}

/**
 * Estudiar demostraciones (preparación «en contexto»): qué se le manda a la IA, la herramienta con la que
 * escribe el paquete y cómo se le presenta después en vivo. Solo datos.
 */
export const KnowledgePrompt = {
  // ---------- Estudio ----------

  studySystem: `You are the assistant in Curiosity. You're going to study demonstrations recorded with a robot (the dataset says which) to write a knowledge package. Later, another session of yours will use it to do the task on a real robot, live, without training any network: it will read your guide, go to the poses you save and replay the segments you choose, adapting them to what it sees.

Each joint's unit is given with the data: degrees (0° is the center of the calibrated travel) or the motor's 0–100 / −100–100 scale. Times are seconds from the start of each demonstration.

Write the package with the write_package tool:
- summary: what the task does and the overall strategy, in 2-4 sentences.
- stages: the stages in order (approach, grasp, lift, carry, release, return…), each with its goal and a concrete, visible check that it was achieved.
- poses: key moments to go to directly (for example "above the object", "grasp", "above the target"): pick the exact demonstration and second from the trajectories I give you.
- segments: segments to replay as-is (for example from the approach to the grasp): demonstration, from and to in seconds. Prefer segments from the cleanest demonstration.
- tips: what you notice matters (speed, order, where the gripper comes from, what fails easily).
Write in English.`,

  writePackage: {
    name: "write_package",
    description: "Saves the studied knowledge package.",
    strict: true,
    input_schema: {
      type: "object",
      additionalProperties: false,
      required: ["title", "summary", "stages", "poses", "segments", "tips"],
      properties: {
        title: { type: "string", description: "Short name of the task." },
        summary: { type: "string" },
        stages: { type: "array", items: object({ name: "string", goal: "string", check: "string" }) },
        poses: { type: "array", items: object({ name: "string", episode: "integer", at_s: "number", note: "string" }) },
        segments: { type: "array", items: object({ name: "string", episode: "integer", from_s: "number", to_s: "number", note: "string" }) },
        tips: { type: "array", items: { type: "string" } },
      },
    },
  } as Json,

  /** El mensaje con todo lo estudiable: datos del dataset, trayectorias (2 por segundo) y las fotos clave. */
  studyMessage(m: StudyMaterial): Json[] {
    const content: Json[] = [];
    const info = m.info;
    const tasks = ((info.tasks as string[]) ?? []).join(" · ");
    const units = (info.joint_units as Record<string, string>) ?? {};
    content.push({
      type: "text",
      text: `Dataset ${m.repoID}: ${info.total_episodes ?? "?"} demonstrations at ${info.fps ?? "?"} fps, robot ${info.robot_type ?? "?"}, cameras ${((info.cameras as string[]) ?? []).join(", ")}. Task: ${tasks}. Trajectory columns: t (s), ${m.joints.map((j) => `${j} (${units[j] ?? "?"})`).join(", ")}.`,
    });
    for (const e of m.episodes) {
      const rows = e.trajectory.filter((_, i) => i % 5 === 0 || i === e.trajectory.length - 1);
      const table = rows.map((r) => r.map((v) => v.toFixed(1)).join(" ")).join("\n");
      const events = e.events.map((ev) => `${ev.t ?? ""} s: gripper ${ev.gripper ?? ""}`).join("; ");
      content.push({
        type: "text",
        text: `Demonstration ${e.index} (${e.duration.toFixed(1)} s). Gripper: ${events || "no clear changes"}.
t shoulder_pan shoulder_lift elbow_flex wrist_flex wrist_roll gripper
${table}`,
      });
    }
    for (const p of m.pictures) {
      content.push({ type: "text", text: `Demonstration ${p.episode}, ${p.label}:` });
      content.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: p.jpeg } });
    }
    content.push({ type: "text", text: "Study everything and write the package with write_package." });
    return content;
  },

  /** Arma el paquete con lo que escribió la IA; las poses salen de las trayectorias reales (no de números copiados). */
  package(input: Json, m: StudyMaterial): KnowledgePackage {
    const byEpisode = new Map(m.episodes.map((e) => [e.index, e.trajectory]));
    const str = (key: string, item: Json) => (typeof item[key] === "string" ? (item[key] as string) : "");
    const number = (key: string, item: Json) => (typeof item[key] === "number" ? (item[key] as number) : 0);
    const poses = ((input.poses as Json[]) ?? []).flatMap((p) => {
      const e = Math.trunc(number("episode", p)), at = number("at_s", p);
      const traj = byEpisode.get(e);
      if (!traj || traj.length === 0) return [];
      const row = traj.reduce((best, r) => (Math.abs(r[0] - at) < Math.abs(best[0] - at) ? r : best));
      if (row.length !== m.joints.length + 1) return [];
      return [{ name: str("name", p), joints: Object.fromEntries(m.joints.map((j, i) => [j, row[i + 1]])), note: str("note", p) }];
    });
    const segments = ((input.segments as Json[]) ?? []).flatMap((s) => {
      const e = Math.trunc(number("episode", s));
      if (!byEpisode.has(e)) return [];
      return [{ name: str("name", s), episode: e, from: number("from_s", s), to: number("to_s", s), note: str("note", s) }];
    });
    return {
      id: uuid(),
      source: m.repoID,
      title: str("title", input),
      createdAt: swiftDate.now(),
      summary: str("summary", input),
      stages: ((input.stages as Json[]) ?? []).map((s) => ({ name: str("name", s), goal: str("goal", s), check: str("check", s) })),
      poses,
      segments,
      tips: ((input.tips as unknown[]) ?? []).filter((t): t is string => typeof t === "string"),
      trajectories: Object.fromEntries(m.episodes.map((e) => [String(e.index), e.trajectory])),
      joints: m.joints,
      pictures: m.pictures.slice(0, 4).map((p) => ({ label: `Demonstration ${p.episode}, ${p.label}`, jpeg: p.jpeg })),
    };
  },

  // ---------- En vivo ----------

  /** Lo que se agrega al prompt del robot en vivo cuando hay un paquete activo. */
  liveSection(k: KnowledgePackage): string {
    const stages = k.stages.map((s, i) => `${i + 1}. ${s.name}: ${s.goal} — achieved if: ${s.check}`);
    const poses = k.poses.map(
      (p) =>
        `- "${p.name}": ` +
        jointOrder(k)
          .filter((j) => p.joints[j] != null)
          .map((j) => `${j} ${RealAgentTools.format(p.joints[j] ?? 0, j)}`)
          .join(", ") +
        (p.note ? ` (${p.note})` : ""),
    );
    const segments = k.segments.map(
      (s) => `- "${s.name}": demonstration ${s.episode}, from ${swiftNumber(s.from)} to ${swiftNumber(s.to)} s${s.note ? ` (${s.note})` : ""}`,
    );
    return `

You studied demonstrations of this task (${k.source}). Your knowledge package:
${k.summary}

Stages:
${stages.join("\n")}

Saved poses (go_to_pose):
${poses.join("\n")}

Segments to replay (play_segment):
${segments.join("\n")}

Tips: ${k.tips.join(" · ")}

How to use it: follow the stages; for each one, recall the matching pose or segment, adapt it to what you see (offsets of a few degrees if the object is somewhere other than in the demonstrations), run it and verify that stage's check with the camera before moving on. The demonstrations may come from another identical robot with a different calibration: treat them as a reference, not exact truth.`;
  },

  /** Se arma en cada uso: las articulaciones son las del robot conectado. */
  get liveTools(): Json[] {
    return [
      {
        name: "go_to_pose",
        strict: true,
        description: "Takes the robot to a saved pose from the knowledge package, with optional adjustments in degrees. Requires approval.",
        input_schema: { type: "object", additionalProperties: false, required: ["name", "offsets"], properties: { name: { type: "string" }, offsets: offsets() } },
      },
      {
        name: "play_segment",
        strict: true,
        description: "Replays on the robot a segment of a demonstration from the package (it first moves slowly to its start). speed from 0.25 to 1 (default 0.5). Requires approval.",
        input_schema: {
          type: "object",
          additionalProperties: false,
          required: ["name", "speed", "offsets"],
          properties: { name: { type: "string" }, speed: { type: "number" }, offsets: offsets() },
        },
      },
    ];
  },
};
