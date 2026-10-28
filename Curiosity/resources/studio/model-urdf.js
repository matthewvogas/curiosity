// URDF → modelo interno del motor.
//
// Modelo interno (el mismo que arma model-mjcf.js):
//   { name, links: [Link], joints: [Joint], cameras: [], home: {}, warnings: [] }
//   Link  = { name, visuals: [Shape], collisions: [Shape], inertial: { pos, quat, mass, inertia: [ixx,iyy,izz] } | null }
//   Shape = { pos, quat, geometry, color }      geometry: mesh {file|url, scale} · box {size} · sphere {radius}
//                                                 · cylinder {radius, length} · capsule {radius, length} · ellipsoid {radii}
//   Joint = { name, type, parent, child, pos, quat,   ← pose del hijo en el marco del padre (pose cero)
//             axis, anchor,                           ← eje y punto de giro en el marco del hijo
//             lower, upper, effort, velocity, damping,
//             actuated, actuator: {kp, kd, fmax} | null, mimic: {joint, multiplier, offset} | null }
//   type: revolute · continuous · prismatic · fixed · floating · spherical
// Cuaterniones como [x, y, z, w]; metros, radianes.

import * as THREE from "three";

const vec = (s, d = [0, 0, 0]) => (s ? s.trim().split(/\s+/).map(Number) : d);
const quatRPY = ([r, p, y]) => {
  const q = new THREE.Quaternion().setFromEuler(new THREE.Euler(r, p, y, "ZYX"));
  return [q.x, q.y, q.z, q.w];
};

function originOf(el) {
  const o = el?.querySelector(":scope > origin");
  return { pos: vec(o?.getAttribute("xyz")), quat: quatRPY(vec(o?.getAttribute("rpy"))) };
}

export function parseURDF(text) {
  const doc = new DOMParser().parseFromString(text, "application/xml");
  const robot = doc.querySelector("robot");
  if (!robot) throw new Error("The file has no <robot>: is it a URDF?");
  const materials = {};
  for (const m of robot.querySelectorAll(":scope > material")) {
    const c = m.querySelector("color");
    if (c) materials[m.getAttribute("name")] = vec(c.getAttribute("rgba"), [0.8, 0.8, 0.8, 1]);
  }
  const geom = (g) => {
    if (!g) return null;
    const mesh = g.querySelector("mesh"), box = g.querySelector("box"), cyl = g.querySelector("cylinder"), sph = g.querySelector("sphere");
    if (mesh) return { type: "mesh", file: mesh.getAttribute("filename"), scale: vec(mesh.getAttribute("scale"), [1, 1, 1]) };
    if (box) return { type: "box", size: vec(box.getAttribute("size")) };
    if (cyl) return { type: "cylinder", radius: +cyl.getAttribute("radius"), length: +cyl.getAttribute("length") };
    if (sph) return { type: "sphere", radius: +sph.getAttribute("radius") };
    return null;
  };
  const shapes = (link, tag) => [...link.querySelectorAll(`:scope > ${tag}`)].map((v) => {
    const mat = v.querySelector("material");
    const rgba = mat?.querySelector("color")?.getAttribute("rgba");
    return { ...originOf(v), geometry: geom(v.querySelector("geometry")), color: rgba ? vec(rgba) : materials[mat?.getAttribute("name")] || null };
  }).filter((s) => s.geometry);

  const links = [...robot.querySelectorAll(":scope > link")].map((l) => {
    const inertial = l.querySelector(":scope > inertial");
    const I = inertial?.querySelector("inertia");
    return {
      name: l.getAttribute("name"),
      visuals: shapes(l, "visual"),
      collisions: shapes(l, "collision"),
      inertial: inertial ? {
        ...originOf(inertial),
        mass: +(inertial.querySelector("mass")?.getAttribute("value") || 0),
        inertia: I ? ["ixx", "iyy", "izz"].map((k) => +(I.getAttribute(k) || 0)) : [0, 0, 0],
      } : null,
    };
  });

  const planar = [...robot.querySelectorAll(":scope > joint[type=planar]")].map((j) => j.getAttribute("name"));
  const joints = [...robot.querySelectorAll(":scope > joint")].map((j) => {
    const lim = j.querySelector("limit"), mimic = j.querySelector("mimic"), dyn = j.querySelector("dynamics");
    const type = j.getAttribute("type");
    return {
      name: j.getAttribute("name"),
      type: type === "planar" ? "fixed" : type,
      parent: j.querySelector("parent").getAttribute("link"),
      child: j.querySelector("child").getAttribute("link"),
      ...originOf(j),
      axis: vec(j.querySelector("axis")?.getAttribute("xyz"), [1, 0, 0]),
      anchor: [0, 0, 0],   // en URDF el eje pasa por el origen del link hijo
      lower: lim ? +(lim.getAttribute("lower") ?? 0) : null,
      upper: lim ? +(lim.getAttribute("upper") ?? 0) : null,
      effort: lim ? +(lim.getAttribute("effort") || 0) : 0,
      velocity: lim ? +(lim.getAttribute("velocity") || 0) : 0,
      damping: dyn ? +(dyn.getAttribute("damping") || 0) : 0,
      actuated: !mimic && type !== "fixed" && type !== "floating",
      actuator: null,
      mimic: mimic ? {
        joint: mimic.getAttribute("joint"),
        multiplier: +(mimic.getAttribute("multiplier") ?? 1),
        offset: +(mimic.getAttribute("offset") ?? 0),
      } : null,
    };
  });
  const warnings = planar.map((n) => `${n}: planar joints aren't supported yet; kept fixed`);
  return { name: robot.getAttribute("name") || "robot", links, joints, cameras: [], home: {}, warnings };
}
