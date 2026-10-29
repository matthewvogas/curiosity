// Arma el MJCF que compila MuJoCo: el robot (desde el modelo interno de un URDF) y la escena con el piso y
// los objetos. Solo texto: sin three.js ni MuJoCo, para poder probarlo aparte.
//
// Colisiones: el robot no choca consigo mismo salvo que se active (contype 2 / conaffinity 1 contra 3);
// el piso y los objetos chocan con todo.

import { partsOf, volume, quatFromEuler, objectQuat, mujocoSize } from "./objects.js";

export const ROBOT_BITS = { contype: 2, conaffinity: 1 }, SELF_BITS = 3, WORLD_BITS = { contype: 1, conaffinity: 3 };

const f = (n) => (Math.abs(n) < 1e-12 ? "0" : String(+Number(n).toPrecision(7)));
const v3 = (a) => a.map(f).join(" ");
const wxyz = (q) => `${f(q[3])} ${f(q[0])} ${f(q[1])} ${f(q[2])}`;  // [x,y,z,w] (three.js) → w x y z (MuJoCo)
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

/**
 * El robot como MJCF.
 * im: modelo interno ({ name, links, joints }) · rootLink: la pieza raíz
 * shapes: Map(link → [{ points: Float32Array } (malla convexa, marco del link) | { geometry, pos, quat } (primitiva)])
 * gains: Map(articulación → { kp, kd, fmax }) de las que llevan motor · params: { timestep, friction }
 */
export function robotXML(im, rootLink, shapes, gains, params) {
  const links = new Map(im.links.map((l) => [l.name, l]));
  const byParent = new Map();
  for (const j of im.joints) { if (!byParent.has(j.parent)) byParent.set(j.parent, []); byParent.get(j.parent).push(j); }
  const meshes = [];
  const geomsOf = (name) => (shapes.get(name) || []).map((s) => {
    if (s.points) {
      const id = `cu_m${meshes.length}`;
      meshes.push(`<mesh name="${id}" vertex="${Array.from(s.points, f).join(" ")}"/>`);
      return `<geom type="mesh" mesh="${id}"/>`;
    }
    const g = s.geometry, at = `pos="${v3(s.pos)}" quat="${wxyz(s.quat)}"`;
    if (g.type === "box") return `<geom type="box" size="${v3(g.size.map((x) => x / 2))}" ${at}/>`;
    if (g.type === "sphere") return `<geom type="sphere" size="${f(g.radius)}" ${at}/>`;
    if (g.type === "ellipsoid") return `<geom type="ellipsoid" size="${v3(g.radii)}" ${at}/>`;
    if (g.type === "capsule") return `<geom type="capsule" size="${f(g.radius)} ${f(g.length / 2)}" ${at}/>`;
    return `<geom type="cylinder" size="${f(g.radius)} ${f(g.length / 2)}" ${at}/>`;
  });
  const inertialOf = (l, hasGeoms) => {
    const i = l?.inertial;
    if (i?.mass > 0) {
      const d = i.inertia.map((x) => Math.max(x, 1e-9));
      return `<inertial pos="${v3(i.pos)}" quat="${wxyz(i.quat)}" mass="${f(i.mass)}" diaginertia="${v3(d)}"/>`;
    }
    // Sin masa declarada: MuJoCo la saca de las formas; si no hay, una mínima para que se pueda mover.
    return hasGeoms ? "" : `<inertial pos="0 0 0" mass="0.0001" diaginertia="1e-9 1e-9 1e-9"/>`;
  };
  const jointOf = (j) => {
    const limited = (j.type === "revolute" || j.type === "prismatic") && j.lower != null && j.upper != null && j.upper > j.lower;
    const common = `name="${esc(j.name)}" pos="${v3(j.anchor || [0, 0, 0])}" damping="${f(j.damping || 0)}" armature="0.002"`;
    if (j.type === "floating") return `<freejoint name="${esc(j.name)}"/>`;
    if (j.type === "spherical") return `<joint type="ball" ${common}/>`;
    if (j.type === "revolute" || j.type === "continuous" || j.type === "prismatic") {
      return `<joint type="${j.type === "prismatic" ? "slide" : "hinge"}" axis="${v3(j.axis)}" ${common}${limited ? ` range="${f(j.lower)} ${f(j.upper)}"` : ""}/>`;
    }
    return "";  // fija: el cuerpo va soldado a su padre
  };
  const body = (name, j, depth) => {
    const l = links.get(name), geoms = geomsOf(name), pad = "  ".repeat(depth);
    const open = j ? `<body name="${esc(name)}" pos="${v3(j.pos)}" quat="${wxyz(j.quat)}">` : `<body name="${esc(name)}">`;
    const inner = [j ? jointOf(j) : "", inertialOf(l, geoms.length > 0), ...geoms].filter(Boolean).map((x) => `${pad}  ${x}`);
    const kids = (byParent.get(name) || []).map((c) => body(c.child, c, depth + 1));
    return [`${pad}${open}`, ...inner, ...kids, `${pad}</body>`].join("\n");
  };

  const tree = body(rootLink, null, 2);
  const actuators = im.joints.filter((j) => gains.has(j.name) && !j.mimic).map((j) => {
    const g = gains.get(j.name);
    const limited = j.lower != null && j.upper != null && j.upper > j.lower;
    return `    <position name="cu_${esc(j.name)}" joint="${esc(j.name)}" kp="${f(g.kp)}" kv="${f(g.kd)}" forcerange="${f(-g.fmax)} ${f(g.fmax)}"${limited ? ` ctrlrange="${f(j.lower)} ${f(j.upper)}"` : ""}/>`;
  });
  // Acopladas (<mimic>): la unión sigue a su maestra con una restricción, como <equality joint> en MuJoCo.
  const mimics = im.joints.filter((j) => j.mimic && im.joints.some((m) => m.name === j.mimic.joint)).map((j) =>
    `    <joint joint1="${esc(j.name)}" joint2="${esc(j.mimic.joint)}" polycoef="${f(j.mimic.offset || 0)} ${f(j.mimic.multiplier ?? 1)} 0 0 0"/>`);

  return `<mujoco model="${esc(im.name || "robot")}">
  <compiler angle="radian" autolimits="true" boundmass="0.00001" boundinertia="1e-10"/>
  <option timestep="${f(params.timestep)}" integrator="implicitfast"/>
  <default>
    <geom contype="${ROBOT_BITS.contype}" conaffinity="${ROBOT_BITS.conaffinity}" condim="3" friction="${f(params.friction)} 0.005 0.0001" group="3"/>
  </default>
  <asset>
    ${meshes.join("\n    ")}
  </asset>
  <worldbody>
${tree}
  </worldbody>
  <equality>
${mimics.join("\n")}
  </equality>
  <actuator>
${actuators.join("\n")}
  </actuator>
</mujoco>
`;
}

const rgba = (hex) => {
  const n = parseInt(String(hex || "#cccccc").replace("#", ""), 16);
  return `${f(((n >> 16) & 255) / 255)} ${f(((n >> 8) & 255) / 255)} ${f((n & 255) / 255)} 1`;
};

/** La escena: el robot (incluido tal cual), el piso y los objetos libres. */
export function sceneXML(robotFile, objects, params) {
  const bodies = objects.map((o) => {
    const parts = partsOf(o);
    const total = parts.reduce((v, p) => v + volume(p), 0) || 1;
    const mass = Math.max(Number(o.mass) || 0.05, 1e-4);
    // Cada pieza lleva la parte de la masa que le toca por su volumen (un escritorio pesa en la tabla y las patas).
    const geoms = parts.map((p) => {
      const type = p.shape === "sphere" ? "sphere" : p.shape === "cylinder" ? "cylinder" : p.shape === "capsule" ? "capsule" : "box";
      return `<geom type="${type}" size="${v3(mujocoSize(p))}" pos="${v3(p.pos)}" quat="${wxyz(quatFromEuler(p.euler))}" mass="${f(Math.max((mass * volume(p)) / total, 1e-5))}" rgba="${rgba(p.color)}" contype="${WORLD_BITS.contype}" conaffinity="${WORLD_BITS.conaffinity}" condim="3" friction="${f(params.friction)} 0.005 0.0001"/>`;
    });
    return `    <body name="cu_obj_${o.id}" pos="${v3(o.pos)}" quat="${wxyz(objectQuat(o))}">${o.fixed ? "" : `<freejoint name="cu_obj_${o.id}"/>`}
      ${geoms.join("\n      ")}
    </body>`;
  });
  return `<mujoco model="curiosity">
  <include file="${esc(robotFile)}"/>
  <worldbody>
    <geom name="cu_floor" type="plane" size="5 5 0.1" contype="${WORLD_BITS.contype}" conaffinity="${WORLD_BITS.conaffinity}" friction="${f(params.friction)} 0.005 0.0001"/>
${bodies.join("\n")}
  </worldbody>
</mujoco>
`;
}
