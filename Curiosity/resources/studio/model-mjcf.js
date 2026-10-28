// MJCF (el formato de MuJoCo) → modelo interno del motor (ver model-urdf.js).
//
// Cubre lo que usan los robots de MuJoCo Menagerie: <include>, clases <default> con herencia y
// childclass, <compiler> (angle, meshdir, eulerseq, autolimits), orientación por quat / euler /
// axisangle / xyaxes / zaxis, cuerpos con varias articulaciones, hinge / slide / ball / free,
// geoms visuales y de colisión (contype, conaffinity, group), actuadores position / motor / general,
// <equality joint> y tendones <fixed> como acoples, cámaras y <keyframe>.
// No cubre (avisa): músculos, tendones espaciales, <equality weld/connect>, cuerpos blandos.

import * as THREE from "three";

const nums = (s, d = null) => (s == null || s === "" ? d : s.trim().split(/\s+/).map(Number));
const Z = new THREE.Vector3(0, 0, 1);

function resolve(base, dir, file) {
  if (/^[a-z]+:\/\//i.test(file)) return file;
  if (file.startsWith("/")) return `curiosity://local/fs${file}`;
  const parts = `${base}/${dir ? dir.replace(/\/$/, "") + "/" : ""}${file}`.split("/");
  const out = [];
  for (const p of parts) {
    if (p === "." || (p === "" && out.length > 3)) continue;
    if (p === ".." && out.length > 3) out.pop(); else out.push(p);
  }
  return out.join("/");
}

/** Reemplaza cada <include file> por el contenido del archivo (recursivo). */
async function expandIncludes(doc, base, depth = 0) {
  if (depth > 8) return;
  for (const inc of [...doc.querySelectorAll("include")]) {
    const url = resolve(base, "", inc.getAttribute("file"));
    const res = await fetch(url);
    if (!res.ok) throw new Error(`No encuentro el archivo incluido ${inc.getAttribute("file")}`);
    const sub = new DOMParser().parseFromString(await res.text(), "application/xml");
    await expandIncludes(sub, base, depth + 1);
    const root = sub.documentElement;
    for (const child of [...root.children]) inc.parentNode.insertBefore(doc.importNode(child, true), inc);
    inc.remove();
  }
}

export async function parseMJCF(text, url) {
  const base = url.slice(0, url.lastIndexOf("/"));
  const doc = new DOMParser().parseFromString(text, "application/xml");
  if (doc.querySelector("parsererror")) throw new Error("El archivo MJCF no es un XML válido.");
  await expandIncludes(doc, base);
  const root = doc.querySelector("mujoco");
  if (!root) throw new Error("El archivo no tiene <mujoco>: ¿es un MJCF?");
  const warnings = [];
  const warn = (w) => { if (!warnings.includes(w)) warnings.push(w); };

  // ---------- compilador ----------
  const comp = { angle: "degree", meshdir: "", assetdir: "", eulerseq: "xyz", autolimits: "true" };
  for (const c of root.querySelectorAll(":scope > compiler")) for (const a of c.attributes) comp[a.name] = a.value;
  const meshdir = comp.meshdir || comp.assetdir || "";
  const angle = (v) => (comp.angle === "degree" ? (v * Math.PI) / 180 : v);

  // ---------- clases por defecto (con herencia) ----------
  const defaults = new Map();
  const attrs = (el) => Object.fromEntries([...el.attributes].map((a) => [a.name, a.value]));
  function readDefault(el, inherited) {
    const cls = el.getAttribute("class") || "main";
    const map = {};
    for (const [tag, a] of Object.entries(inherited)) map[tag] = { ...a };
    for (const child of el.children) {
      if (child.tagName !== "default") map[child.tagName] = { ...(map[child.tagName] || {}), ...attrs(child) };
    }
    defaults.set(cls, map);
    for (const child of el.children) if (child.tagName === "default") readDefault(child, map);
  }
  for (const d of root.querySelectorAll(":scope > default")) readDefault(d, defaults.get("main") || {});
  /** Atributo con su clase por defecto (la propia, la heredada del cuerpo o «main»). */
  const get = (el, name, cls) => {
    if (el.hasAttribute(name)) return el.getAttribute(name);
    const c = el.getAttribute("class") || cls || "main";
    return defaults.get(c)?.[el.tagName]?.[name] ?? defaults.get("main")?.[el.tagName]?.[name] ?? null;
  };

  // ---------- orientación ----------
  function orient(el, cls) {
    const q = new THREE.Quaternion();
    const quat = nums(get(el, "quat", cls));
    if (quat) return q.set(quat[1], quat[2], quat[3], quat[0]).normalize();   // MJCF: w x y z
    const aa = nums(get(el, "axisangle", cls));
    if (aa) return q.setFromAxisAngle(new THREE.Vector3(aa[0], aa[1], aa[2]).normalize(), angle(aa[3]));
    const eu = nums(get(el, "euler", cls));
    if (eu) {
      const seq = comp.eulerseq;
      for (let i = 0; i < 3; i++) {
        const ax = { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] }[seq[i].toLowerCase()];
        const r = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(...ax), angle(eu[i]));
        if (seq[i] === seq[i].toLowerCase()) q.multiply(r); else q.premultiply(r);   // minúscula: ejes móviles
      }
      return q;
    }
    const xy = nums(get(el, "xyaxes", cls));
    if (xy) {
      const x = new THREE.Vector3(xy[0], xy[1], xy[2]).normalize();
      const y = new THREE.Vector3(xy[3], xy[4], xy[5]);
      y.sub(x.clone().multiplyScalar(y.dot(x))).normalize();
      const z = new THREE.Vector3().crossVectors(x, y);
      return q.setFromRotationMatrix(new THREE.Matrix4().makeBasis(x, y, z));
    }
    const za = nums(get(el, "zaxis", cls));
    if (za) return q.setFromUnitVectors(Z, new THREE.Vector3(...za).normalize());
    return q;
  }
  const qa = (q) => [q.x, q.y, q.z, q.w];

  // ---------- assets ----------
  const meshes = {}, materials = {};
  for (const m of root.querySelectorAll(":scope > asset > mesh")) {
    const file = m.getAttribute("file");
    if (!file) { warn(`malla «${m.getAttribute("name")}» sin archivo (definida por vértices): pendiente`); continue; }
    const name = m.getAttribute("name") || file.split("/").pop().replace(/\.[^.]+$/, "");
    meshes[name] = { url: resolve(base, meshdir, file), scale: nums(get(m, "scale"), [1, 1, 1]) };
  }
  for (const m of root.querySelectorAll(":scope > asset > material")) {
    materials[m.getAttribute("name")] = nums(get(m, "rgba"), null);
  }

  // ---------- geoms ----------
  function makeGeom(el, cls) {
    const type = get(el, "type", cls) || "sphere";
    if (type === "plane" || type === "hfield" || type === "sdf") return null;
    const size = nums(get(el, "size", cls), [0.01, 0.01, 0.01]);
    let pos = nums(get(el, "pos", cls), [0, 0, 0]), q = orient(el, cls), length = null;
    const fromto = nums(get(el, "fromto", cls));
    if (fromto) {
      const a = new THREE.Vector3(fromto[0], fromto[1], fromto[2]), b = new THREE.Vector3(fromto[3], fromto[4], fromto[5]);
      pos = qa(a.clone().add(b).multiplyScalar(0.5)).slice(0, 3);
      length = a.distanceTo(b);
      q = new THREE.Quaternion().setFromUnitVectors(Z, b.clone().sub(a).normalize());
    }
    let geometry;
    switch (type) {
      case "box": geometry = { type: "box", size: [2 * size[0], 2 * (size[1] ?? size[0]), 2 * (size[2] ?? size[0])] }; break;
      case "sphere": geometry = { type: "sphere", radius: size[0] }; break;
      case "capsule": geometry = { type: "capsule", radius: size[0], length: length ?? 2 * (size[1] ?? 0) }; break;
      case "cylinder": geometry = { type: "cylinder", radius: size[0], length: length ?? 2 * (size[1] ?? 0) }; break;
      case "ellipsoid": geometry = { type: "ellipsoid", radii: [size[0], size[1] ?? size[0], size[2] ?? size[0]] }; break;
      case "mesh": {
        const m = meshes[get(el, "mesh", cls)];
        if (!m) { warn(`geom con malla desconocida «${get(el, "mesh", cls)}»`); return null; }
        geometry = { type: "mesh", url: m.url, scale: m.scale };
        break;
      }
      default: warn(`geom de tipo «${type}» pendiente`); return null;
    }
    const rgba = nums(get(el, "rgba", cls)) || materials[get(el, "material", cls)] || null;
    const contype = +(get(el, "contype", cls) ?? 1), conaffinity = +(get(el, "conaffinity", cls) ?? 1);
    const group = +(get(el, "group", cls) ?? 0);
    return {
      shape: { pos, quat: qa(q), geometry, color: rgba },
      visible: group < 3,                       // MuJoCo muestra los grupos 0, 1 y 2
      collides: (contype | conaffinity) !== 0,
    };
  }

  // ---------- cuerpos y articulaciones ----------
  const world = { name: "world", visuals: [], collisions: [], inertial: null };
  const links = [world], joints = [], cameras = [], qposOrder = [];
  let unnamed = 0;

  function addGeoms(el, link, cls) {
    for (const g of el.querySelectorAll(":scope > geom")) {
      const r = makeGeom(g, cls);
      if (!r) continue;
      if (r.visible) link.visuals.push(r.shape);
      if (r.collides) link.collisions.push(r.shape);
    }
  }

  function makeJoint(je, parent, child, pos, quat, cls, index) {
    const common = { parent, child, pos, quat, anchor: nums(get(je, "pos", cls), [0, 0, 0]), effort: 0, velocity: 0,
      actuated: false, actuator: null, mimic: null, lower: null, upper: null, axis: [0, 0, 1], damping: 0 };
    const name = je.getAttribute("name") || `${child}_${index}`;
    const type = je.tagName === "freejoint" ? "free" : get(je, "type", cls) || "hinge";
    if (type === "free") { qposOrder.push([name, 7]); return { ...common, name, type: "floating", anchor: [0, 0, 0] }; }
    if (type === "ball") { qposOrder.push([name, 4]); return { ...common, name, type: "spherical" }; }
    qposOrder.push([name, 1]);
    const range = nums(get(je, "range", cls));
    const lim = get(je, "limited", cls);
    const limited = lim === "true" || ((lim == null || lim === "auto") && comp.autolimits !== "false" && range != null);
    const slide = type === "slide";
    return {
      ...common, name,
      type: slide ? "prismatic" : limited ? "revolute" : "continuous",
      axis: nums(get(je, "axis", cls), [0, 0, 1]),
      lower: limited ? (slide ? range[0] : angle(range[0])) : null,
      upper: limited ? (slide ? range[1] : angle(range[1])) : null,
      damping: +(get(je, "damping", cls) || 0),
    };
  }

  function walk(bodyEl, parent, cls) {
    const childcls = bodyEl.getAttribute("childclass") || cls;
    const name = bodyEl.getAttribute("name") || `body${++unnamed}`;
    const pos = nums(bodyEl.getAttribute("pos"), [0, 0, 0]), quat = qa(orient(bodyEl, null));
    const link = { name, visuals: [], collisions: [], inertial: null };

    // Varias articulaciones en un cuerpo: cadena de cuerpos virtuales sin masa en el mismo lugar.
    const jointEls = [...bodyEl.children].filter((c) => c.tagName === "joint" || c.tagName === "freejoint");
    if (!jointEls.length) {
      joints.push({ name: `${name}_fixed`, type: "fixed", parent, child: name, pos, quat, anchor: [0, 0, 0], axis: [0, 0, 1],
        lower: null, upper: null, effort: 0, velocity: 0, damping: 0, actuated: false, actuator: null, mimic: null });
    }
    let prev = parent;
    jointEls.forEach((je, i) => {
      const last = i === jointEls.length - 1, child = last ? name : `${name}__${i}`;
      if (!last) links.push({ name: child, visuals: [], collisions: [], inertial: null, virtual: true });
      joints.push(makeJoint(je, prev, child, i === 0 ? pos : [0, 0, 0], i === 0 ? quat : [0, 0, 0, 1], childcls, i));
      prev = child;
    });

    addGeoms(bodyEl, link, childcls);
    const inertial = bodyEl.querySelector(":scope > inertial");
    if (inertial) {
      const diag = nums(inertial.getAttribute("diaginertia")), full = nums(inertial.getAttribute("fullinertia"));
      link.inertial = {
        pos: nums(inertial.getAttribute("pos"), [0, 0, 0]), quat: qa(orient(inertial, null)),
        mass: +(inertial.getAttribute("mass") || 0),
        inertia: diag || (full ? full.slice(0, 3) : [1e-6, 1e-6, 1e-6]),
      };
    }
    for (const c of bodyEl.querySelectorAll(":scope > camera")) {
      const q = orient(c, childcls);
      cameras.push({ name: c.getAttribute("name") || `${name} cámara`, link: name, pos: nums(get(c, "pos", childcls), [0, 0, 0]),
        quat: qa(q), fovy: +(get(c, "fovy", childcls) || 45), width: 640, height: 480 });
    }
    links.push(link);
    for (const b of bodyEl.querySelectorAll(":scope > body")) walk(b, name, childcls);
  }

  const worldbody = root.querySelector(":scope > worldbody");
  if (!worldbody) throw new Error("El MJCF no tiene <worldbody>.");
  addGeoms(worldbody, world, null);
  for (const b of worldbody.querySelectorAll(":scope > body")) walk(b, "world", null);
  const byName = new Map(joints.map((j) => [j.name, j]));

  // ---------- tendones fijos (acoples, típicos de las pinzas) ----------
  const tendons = new Map();
  for (const t of root.querySelectorAll(":scope > tendon > fixed")) {
    tendons.set(t.getAttribute("name"), [...t.querySelectorAll(":scope > joint")].map((j) => ({ joint: j.getAttribute("joint"), coef: +(j.getAttribute("coef") || 1) })));
  }
  if (root.querySelector(":scope > tendon > spatial")) warn("tendones espaciales: pendiente");

  // ---------- actuadores ----------
  for (const a of root.querySelectorAll(":scope > actuator > *")) {
    const tag = a.tagName;
    const cls = a.getAttribute("class");
    let target = get(a, "joint", cls);
    const tendon = get(a, "tendon", cls);
    if (!target && tendon && tendons.has(tendon)) {
      // Un actuador sobre un tendón fijo: mueve la primera articulación y las otras la siguen.
      const parts = tendons.get(tendon);
      target = parts[0].joint;
      for (const p of parts.slice(1)) {
        const j = byName.get(p.joint);
        if (j && !j.mimic) j.mimic = { joint: target, multiplier: p.coef / parts[0].coef, offset: 0 };
      }
    }
    const j = byName.get(target);
    if (!j) { warn(`actuador «${a.getAttribute("name") || tag}» sobre algo que no es una articulación: pendiente`); continue; }
    const ctrl = nums(get(a, "ctrlrange", cls)), force = nums(get(a, "forcerange", cls));
    const gear = nums(get(a, "gear", cls), [1])[0];
    const span = j.lower != null ? j.upper - j.lower : Math.PI;
    let kp, kd, fmax;
    if (tag === "position") {
      kp = +(get(a, "kp", cls) || 1);
      kd = +(get(a, "kv", cls) || 0) || kp * 0.05;
      fmax = force ? Math.max(...force.map(Math.abs)) : kp * span;
    } else if (tag === "general") {
      const gain = nums(get(a, "gainprm", cls), [1]), bias = nums(get(a, "biasprm", cls), [0, 0, 0]);
      kp = gain[0] || 1;
      kd = -(bias[2] || 0) || kp * 0.05;
      fmax = force ? Math.max(...force.map(Math.abs)) : ctrl ? kp * Math.max(...ctrl.map(Math.abs)) : kp * span;
    } else if (tag === "motor") {
      // Motor de torque: aquí se aproxima con un servo de posición con su misma fuerza máxima.
      fmax = (force ? Math.max(...force.map(Math.abs)) : ctrl ? Math.max(...ctrl.map(Math.abs)) : 10) * Math.abs(gear);
      kp = fmax * 10;
      kd = kp * 0.05;
    } else {
      warn(`actuador de tipo «${tag}»: se aproxima con un servo de posición`);
      kp = 10; kd = 0.5; fmax = 10;
    }
    j.actuated = !j.mimic;
    j.actuator = { kp, kd, fmax };
    j.effort = fmax;
  }

  // ---------- igualdades ----------
  for (const e of root.querySelectorAll(":scope > equality > *")) {
    if (e.tagName === "joint") {
      const j1 = byName.get(e.getAttribute("joint1")), j2 = e.getAttribute("joint2");
      const pc = nums(e.getAttribute("polycoef"), [0, 1, 0, 0, 0]);
      const other = byName.get(j2);
      if (!j1 || !other || j1 === other) continue;
      // q1 = c0 + c1·q2. Si q1 ya tiene actuador (o q2 ya sigue a q1), se invierte para no hacer un círculo.
      const follows = (a, b) => a.mimic?.joint === b.name;
      if (follows(j1, other) || follows(other, j1)) continue;
      if (j1.actuated && !other.actuated && pc[1]) {
        other.mimic = { joint: j1.name, multiplier: 1 / pc[1], offset: -pc[0] / pc[1] };
        other.actuated = false;
      } else if (!j1.mimic) {
        j1.mimic = { joint: other.name, multiplier: pc[1], offset: pc[0] };
        j1.actuated = false;
      }
    } else {
      warn(`restricción <${e.tagName}>: pendiente (algunas piezas pueden quedar sueltas)`);
    }
  }

  // ---------- keyframe: la pose «home» ----------
  const keys = [...root.querySelectorAll(":scope > keyframe > key")];
  const key = keys.find((k) => k.getAttribute("name") === "home") || keys[0];
  const home = {};
  const qpos = nums(key?.getAttribute("qpos"));
  if (qpos) {
    let i = 0;
    for (const [name, size] of qposOrder) {
      const j = byName.get(name);
      if (size === 1 && j) home[name] = qpos[i];
      i += size;
    }
  }

  if (root.querySelector(":scope > actuator > muscle")) warn("músculos: pendiente");
  return { name: root.getAttribute("model") || "robot", links, joints, cameras, home, warnings };
}
