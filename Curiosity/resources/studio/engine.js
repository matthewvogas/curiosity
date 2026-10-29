// Motor de simulación de Curiosity Studio. Agnóstico al robot: cualquier URDF o MJCF con física de MuJoCo
// (el binding oficial de Google DeepMind, compilado a WebAssembly) y three.js para dibujar.
//
//  · MJCF: MuJoCo lo carga tal cual (con sus actuadores, tendones, igualdades y contactos).
//  · URDF: se arma un MJCF desde el modelo interno (mjcf-build.js): cuerpos con su masa e inercia,
//    colisiones convexas (las mallas cóncavas se parten con decompose.js), un actuador de posición por
//    articulación móvil (kp, kv, fuerza máxima) y las <mimic> como igualdades.
//  · La escena (piso y objetos libres) envuelve al robot con <include>; agregar o quitar un objeto recompila.
//  · Sensores: posición, velocidad y fuerza de cada articulación; contactos y fuerza por pieza.
//  · Cámaras montadas en cualquier pieza, pausa, paso a paso y velocidad.
//
// Convenciones: el mundo es z hacia arriba, metros, radianes. three.js es y-arriba, así que todo cuelga de
// un grupo girado −90° en x. Cada pieza se dibuja en su propio marco, el de su cuerpo en MuJoCo.
//
// La app nativa lo maneja con window.studio.* y recibe el estado por webkit.messageHandlers.studio.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { ColladaLoader } from "three/addons/loaders/ColladaLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { ConvexGeometry } from "three/addons/geometries/ConvexGeometry.js";
import loadMujoco from "./lib/mujoco/mujoco.js";
import { parseURDF } from "./model-urdf.js";
import { parseMJCF } from "./model-mjcf.js";
import { triangles, decompose } from "./decompose.js";
import { robotXML, sceneXML, ROBOT_BITS, SELF_BITS } from "./mjcf-build.js";
import { createSkills } from "./skills.js";
import { partsOf, quatFromEuler, objectQuat, bounds } from "./objects.js";

let mj = null;   // el módulo de MuJoCo
// macOS (SwiftUI): webkit.messageHandlers. Escritorio (Tauri): la app que contiene el visor, por postMessage.
const post = (msg) => {
  try {
    if (window.webkit?.messageHandlers?.studio) window.webkit.messageHandlers.studio.postMessage(msg);
    else if (window.parent !== window) window.parent.postMessage({ studio: msg }, "*");
  } catch { /* fuera de la app no hay a quién avisar */ }
};
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

// Tipos de objeto de MuJoCo (mjtObj) que se buscan por nombre.
const OBJ_BODY = 1, OBJ_JOINT = 3, OBJ_ACTUATOR = 19;

// ---------- estado ----------
let renderer, scene, camera, controls, root, markers, ground, grid;
let mjm = null, mjd = null;       // MjModel y MjData de la escena actual
let files = null;                  // { dir, robot }: dónde quedó el robot en el sistema de archivos de MuJoCo
let loadCount = 0, forceBuf = null;
let model = null;               // { name, links: Map, joints: [], rootLink }
let objects = [];               // objetos libres de la escena
let cameras = [];               // cámaras montadas en links
let activeCamera = null, pipRenderer = null;
let mode = "sim";               // sim · mirror (los motores siguen al robot real)
let paused = false, speed = 1, simTime = 0, wallLast = 0, rtf = 0, accum = 0;
let lastPost = 0, nextObjectId = 1;
let readout = { contacts: 0, maxForce: 0, links: {} };
let insetRight = 0;     // px que tapa un panel flotante a la derecha
let homeTargets = {};  // pose de reposo del perfil (si no, cero)
const params = {
  gravity: 9.81, timestep: 1 / 500, iterations: 8, friction: 0.7, restitution: 0.05,
  selfCollision: false, fixedBase: true,
  noiseScale: 0, noiseRate: 0,   // ruido en el control (como MuJoCo): escala relativa al rango y tiempo de correlación (s)
};
// Qué se dibuja (panel «Visualización»): como los flags de render de MuJoCo.
const render = { contacts: true, joints: false, collision: false, com: false, transparent: false, grid: true, shadows: true };
let stepMs = 0;   // profiler: tiempo medio de un paso de física
let effectorConfig = null;  // «effector» del perfil (punta y pinza), si lo trae
// Habilidades (agarrar, dejar…) que se mueven solas en tiempo real; ver skills.js.
const skills = createSkills({ get: () => ({ mj, mjm, mjd, model, root, cameras }), config: () => effectorConfig });

// ---------- utilidades de geometría ----------
const vec = (s, d = [0, 0, 0]) => (s ? s.trim().split(/\s+/).map(Number) : d);
const quatRPY = ([r, p, y]) => new THREE.Quaternion().setFromEuler(new THREE.Euler(r, p, y, "ZYX"));

const debugMaterials = {
  collision: new THREE.MeshBasicMaterial({ color: 0x4ea7fc, wireframe: true, transparent: true, opacity: 0.55 }),
  com: new THREE.MeshBasicMaterial({ color: 0xf2c94c, depthTest: false }),
};

function applyRender() {
  if (!root) return;
  root.traverse((o) => {
    const layer = o.userData?.layer;
    if (layer) o.visible = !!render[layer];
    if (o.userData?.robotVisual && o.material) {
      o.material.transparent = render.transparent || o.userData.baseOpacity < 1;
      o.material.opacity = render.transparent ? 0.35 : o.userData.baseOpacity;
      o.material.depthWrite = !render.transparent;
    }
  });
  if (grid) grid.visible = render.grid;
  if (ground) ground.visible = render.shadows;
  if (renderer) renderer.shadowMap.enabled = render.shadows;
  for (const o of root.children) o.traverse?.((m) => { if (m.isMesh) m.castShadow = render.shadows && !m.userData?.layer; });
}

// ---------- mallas ----------
const meshCache = new Map();
async function fetchFirst(urls) {
  for (const u of urls) {
    try { const r = await fetch(u); if (r.ok) return { url: u, buf: await r.arrayBuffer() }; } catch { /* siguiente */ }
  }
  return null;
}
function candidates(file, base) {
  // package://paquete/resto → se busca subiendo desde la carpeta del URDF (convención de ROS).
  if (file.startsWith("package://")) {
    const rest = file.slice("package://".length).split("/").slice(1).join("/");
    return [`${base}/${rest}`, `${base}/../${rest}`, `${base}/../../${rest}`, `${base}/${file.slice(10)}`];
  }
  if (file.startsWith("file://")) return [`curiosity://local/fs${file.slice(7)}`];
  if (file.startsWith("/")) return [`curiosity://local/fs${file}`];
  return [`${base}/${file}`];
}
async function loadMesh(file, base, url = null) {
  const key = url || `${base}|${file}`;
  if (!meshCache.has(key)) {
    meshCache.set(key, (async () => {
      const hit = await fetchFirst(url ? [url] : candidates(file, base));
      file = file || url;
      if (!hit) throw new Error(`Can't find the mesh ${file}`);
      const ext = file.split(".").pop().toLowerCase();
      if (ext === "stl") {
        const g = new STLLoader().parse(hit.buf);
        g.computeVertexNormals();
        return new THREE.Mesh(g);
      }
      const text = new TextDecoder().decode(hit.buf);
      if (ext === "obj") return new OBJLoader().parse(text);
      if (ext === "dae") {
        const dae = new ColladaLoader().parse(text, hit.url.slice(0, hit.url.lastIndexOf("/") + 1));
        dae.scene.rotation.set(0, 0, 0);  // el URDF ya trae su orientación
        return dae.scene;
      }
      throw new Error(`Unsupported mesh format: .${ext}`);
    })());
  }
  return (await meshCache.get(key)).clone(true);
}

function primitive(g) {
  if (g.type === "box") return new THREE.BoxGeometry(...g.size);
  if (g.type === "sphere") return new THREE.SphereGeometry(g.radius, 32, 16);
  if (g.type === "ellipsoid") return new THREE.SphereGeometry(1, 32, 16).scale(...g.radii);
  // Cilindros y cápsulas van a lo largo de z (URDF y MJCF); en three.js, a lo largo de y.
  if (g.type === "capsule") return new THREE.CapsuleGeometry(g.radius, g.length, 8, 24).rotateX(Math.PI / 2);
  return new THREE.CylinderGeometry(g.radius, g.radius, g.length, 32).rotateX(Math.PI / 2);
}

async function shapeObject(s, base) {
  const g = s.geometry;
  if (g.type !== "mesh") return new THREE.Mesh(primitive(g));
  const obj = await loadMesh(g.file, base, g.url);
  obj.scale.set(...g.scale);
  return obj;
}

const arrQ = (a) => new THREE.Quaternion(a[0], a[1], a[2], a[3]);

function materialFor(color) {
  const [r, g, b, a] = color || [0.86, 0.86, 0.84, 1];
  return new THREE.MeshStandardMaterial({
    color: new THREE.Color(r, g, b), roughness: 0.55, metalness: 0.05,
    transparent: a < 1, opacity: a,
  });
}

/** Puntos (en el marco del cuerpo) de una forma, para su envolvente convexa. */
function hullPoints(object3d, bodyMatrix) {
  const pts = [], v = new THREE.Vector3();
  object3d.updateMatrixWorld(true);
  object3d.traverse((o) => {
    if (!o.isMesh) return;
    const pos = o.geometry.attributes.position;
    const m = new THREE.Matrix4().multiplyMatrices(bodyMatrix, o.matrixWorld);
    const step = Math.max(1, Math.floor(pos.count / 3000));  // basta una muestra para la envolvente
    for (let i = 0; i < pos.count; i += step) { v.fromBufferAttribute(pos, i).applyMatrix4(m); pts.push(v.x, v.y, v.z); }
  });
  return new Float32Array(pts);
}

// ---------- construir el modelo ----------
/** Arma las piezas que se dibujan y, para un URDF, las formas de colisión que irán al MJCF. */
async function buildModel(im, base, profile, native) {
  const links = new Map(im.links.map((l) => [l.name, l]));
  const childOf = new Set(im.joints.map((j) => j.child));
  const rootLink = im.links.find((l) => !childOf.has(l.name))?.name;
  if (!rootLink) throw new Error("The model has no root link.");
  const decomposeParts = profile?.collision?.maxParts ?? 8;
  const byParent = new Map();
  for (const j of im.joints) { if (!byParent.has(j.parent)) byParent.set(j.parent, []); byParent.get(j.parent).push(j); }
  const order = [rootLink];
  for (let i = 0; i < order.length; i++) for (const j of byParent.get(order[i]) || []) if (!order.includes(j.child)) order.push(j.child);

  const warnings = [...(im.warnings || [])];
  const out = { name: im.name, links: new Map(), joints: [], rootLink, mass: 0, native,
    floating: im.joints.some((j) => j.type === "floating"), shapes: new Map(), gains: new Map() };
  let decomposed = 0;
  const identity = new THREE.Matrix4();
  for (const name of order) {
    const l = links.get(name);
    // Se agrega a la escena en loadNow, solo si esta carga sigue vigente: una vieja no deja piezas sueltas.
    const group = new THREE.Group();

    // Visual, en el marco de la pieza (MuJoCo da la pose de ese marco).
    for (const v of l.visuals) {
      try {
        const obj = await shapeObject(v, base);
        const mat = materialFor(v.color);
        obj.traverse((o) => {
          if (!o.isMesh) return;
          if (v.geometry.type !== "mesh" || v.color || !o.material?.map) o.material = mat.clone();
          o.castShadow = o.receiveShadow = true;
          o.userData.robotVisual = true;
          o.userData.baseOpacity = o.material.opacity ?? 1;
        });
        const off = new THREE.Group();
        off.position.set(...v.pos);
        off.quaternion.copy(arrQ(v.quat));
        off.add(obj);
        group.add(off);
      } catch (e) { warnings.push(`${name}: ${e.message}`); }
    }

    // Colisión (solo URDF; un MJCF trae las suyas): primitivas tal cual, mallas en partes convexas.
    if (!native) {
      const list = [];
      for (const s of l.collisions.length ? l.collisions : l.visuals) {
        try {
          if (s.geometry.type !== "mesh") { list.push({ geometry: s.geometry, pos: s.pos, quat: s.quat }); continue; }
          const obj = await shapeObject(s, base);
          const off = new THREE.Group();
          off.position.set(...s.pos);
          off.quaternion.copy(arrQ(s.quat));
          off.add(obj);
          const { parts } = decompose(triangles(off, identity), decomposeParts);
          if (parts.length > 1) decomposed++;
          for (const pts of parts) {
            if (pts.length < 12) continue;
            list.push({ points: pts });
            try {
              const vs = [];
              for (let i = 0; i < pts.length; i += 3) vs.push(new THREE.Vector3(pts[i], pts[i + 1], pts[i + 2]));
              const hull = new THREE.Mesh(new ConvexGeometry(vs), debugMaterials.collision);
              hull.userData.layer = "collision";
              hull.visible = render.collision;
              group.add(hull);
            } catch { /* sin malla de depuración */ }
          }
        } catch (e) { warnings.push(`${name}: ${e.message}`); }
      }
      out.shapes.set(name, list);
    }

    const com = new THREE.Mesh(new THREE.SphereGeometry(0.006, 12, 8), debugMaterials.com);
    com.userData.layer = "com";
    com.visible = render.com;
    group.add(com);
    out.links.set(name, { name, group, com, virtual: !!l.virtual, body: -1 });
  }
  if (decomposed) warnings.push(`${decomposed} concave links were split into convex shapes for better collisions`);

  // Articulaciones que se muestran y se mandan.
  for (const j of im.joints) {
    if (!["revolute", "continuous", "prismatic"].includes(j.type)) continue;
    const child = out.links.get(j.child);
    if (!child) continue;
    const arrow = new THREE.ArrowHelper(new THREE.Vector3(...j.axis).normalize(), new THREE.Vector3(...(j.anchor || [0, 0, 0])), 0.05, 0xff4fa3, 0.012, 0.008);
    arrow.userData.layer = "joints";
    arrow.visible = render.joints;
    child.group.add(arrow);

    const limited = (j.type === "revolute" || j.type === "prismatic") && j.lower != null && j.upper != null && j.upper > j.lower;
    const saved = profile?.actuators?.[j.name] || {};
    const act = j.actuator || {};
    const fmax = saved.fmax ?? act.fmax ?? (j.effort > 0 ? j.effort : 10);
    const kp = saved.kp ?? act.kp ?? fmax * 10;            // fuerza máxima con ~0.1 rad (o m) de error
    const kd = saved.kd ?? act.kd ?? kp * 0.05;
    if (j.actuated && !j.mimic) out.gains.set(j.name, { kp, kd, fmax });
    out.joints.push({
      name: j.name, type: j.type, parent: j.parent, child: j.child,
      lower: limited ? j.lower : null, upper: limited ? j.upper : null,
      effort: j.effort, velocity: j.velocity, kp, kd, fmax,
      actuated: !!j.actuated, mimic: j.mimic, driven: !!j.actuated && !j.mimic,
      target: limited ? clamp(0, j.lower, j.upper) : 0, q: 0, qd: 0, force: 0,
      jid: -1, qadr: -1, dadr: -1, aid: -1, servo: false, gear: 1,
    });
  }
  const rank = new Map(order.map((n, i) => [n, i]));
  out.joints.sort((a, b) => rank.get(a.child) - rank.get(b.child));
  const byName = new Map(out.joints.map((j) => [j.name, j]));
  for (const j of out.joints) if (j.mimic) j.master = byName.get(j.mimic.joint) || null;
  // El árbol completo (también las uniones fijas): de cada pieza, su pieza madre.
  out.parentOf = new Map(im.joints.map((j) => [j.child, j.parent]));
  return { ...out, warnings };
}

// ---------- MuJoCo ----------
const fsPath = (...parts) => parts.join("/").replace(/\/+/g, "/");
function mkdirs(path) { try { mj.FS.mkdirTree(path); } catch { /* ya existe */ } }
function rmTree(path) {
  try {
    for (const name of mj.FS.readdir(path)) {
      if (name === "." || name === "..") continue;
      const p = `${path}/${name}`;
      if (mj.FS.isDir(mj.FS.stat(p).mode)) rmTree(p); else mj.FS.unlink(p);
    }
    mj.FS.rmdir(path);
  } catch { /* nada que borrar */ }
}

const GRAY_PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGOYCQAAmwCarS5ItAAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));

/** Un MJCF con todo lo que usa (include, mallas, texturas), copiado al sistema de archivos de MuJoCo. */
async function writeMJCF(text, url, dir) {
  const base = url.slice(0, url.lastIndexOf("/") + 1);
  const seen = new Set();
  const visit = async (xml) => {
    const doc = new DOMParser().parseFromString(xml, "text/xml");
    const compiler = doc.querySelector("compiler");
    const assetdir = compiler?.getAttribute("assetdir") || "";
    const meshdir = compiler?.getAttribute("meshdir") ?? assetdir;
    const texturedir = compiler?.getAttribute("texturedir") ?? assetdir;
    const wanted = [];
    for (const el of doc.querySelectorAll("*")) {
      const tag = el.tagName.toLowerCase();
      for (const attr of el.getAttributeNames().filter((a) => a.startsWith("file"))) {
        const file = el.getAttribute(attr);
        if (tag === "include") wanted.push({ path: file, include: true });
        else wanted.push({ path: fsPath(tag === "texture" ? texturedir : ["mesh", "skin", "hfield"].includes(tag) ? meshdir : "", file) });
      }
    }
    for (const w of wanted) {
      const path = fsPath(w.path);
      if (seen.has(path)) continue;
      seen.add(path);
      try {
        const res = await fetch(base + path);
        if (!res.ok) {
          // Una textura que no está no debe tumbar el modelo entero: va un píxel gris en su lugar.
          if (/\.png$/i.test(path)) { mkdirs(fsPath(dir, path.slice(0, path.lastIndexOf("/") + 1))); mj.FS.writeFile(fsPath(dir, path), GRAY_PNG); }
          continue;
        }
        const buf = new Uint8Array(await res.arrayBuffer());
        mkdirs(fsPath(dir, path.slice(0, path.lastIndexOf("/") + 1)));
        mj.FS.writeFile(fsPath(dir, path), buf);
        if (w.include) await visit(new TextDecoder().decode(buf));
      } catch { /* MuJoCo dirá cuál falta */ }
    }
  };
  await visit(text);
}

/** Compila la escena (robot + piso + objetos) y conserva el estado del robot y los objetos si ya había. */
function compileScene() {
  const sceneFile = fsPath(files.dir, "cu_scene.xml");
  mj.FS.writeFile(sceneFile, sceneXML(files.robot, objects, params));
  const keep = mjd ? Object.fromEntries(model.joints.filter((j) => j.qadr >= 0).map((j) => [j.name, [mjd.qpos[j.qadr], mjd.qvel[j.dadr]]])) : null;
  const objectPose = mjd ? Object.fromEntries(objects.filter((o) => o.body >= 0).map((o) => [o.id, objectState(o)])) : {};
  const next = mj.MjModel.from_xml_path(sceneFile);
  mjd?.delete(); mjm?.delete();
  mjm = next;
  mjd = new mj.MjData(mjm);
  bind();
  applyPhysics();
  if (keep) for (const j of model.joints) if (keep[j.name] && j.qadr >= 0) { mjd.qpos[j.qadr] = keep[j.name][0]; mjd.qvel[j.dadr] = keep[j.name][1]; }
  for (const o of objects) if (objectPose[o.id]) setObjectState(o, objectPose[o.id]);
  mj.mj_forward(mjm, mjd);
}

/** Une cada pieza, articulación y objeto con su índice en el modelo compilado. */
function bind() {
  for (const l of model.links.values()) {
    l.body = mj.mj_name2id(mjm, OBJ_BODY, l.name);
    if (l.body >= 0) l.com.position.set(mjm.body_ipos[l.body * 3], mjm.body_ipos[l.body * 3 + 1], mjm.body_ipos[l.body * 3 + 2]);
  }
  const actuatorOf = new Map();
  for (let a = 0; a < mjm.nu; a++) if (mjm.actuator_trntype[a] === 0) actuatorOf.set(mjm.actuator_trnid[a * 2], a);
  // Actuadores sobre un tendón fijo (p. ej. los dedos de la Panda): mueven las articulaciones que el tendón suma.
  const tendonOf = new Map();   // articulación → { a, coef }
  for (let a = 0; a < mjm.nu; a++) {
    if (mjm.actuator_trntype[a] !== 3) continue;   // mjTRN_TENDON
    const t = mjm.actuator_trnid[a * 2], adr = mjm.tendon_adr[t], num = mjm.tendon_num[t];
    let coef = 0;
    const joints = [];
    for (let w = adr; w < adr + num; w++) if (mjm.wrap_type[w] === 1) { coef += mjm.wrap_prm[w]; joints.push(mjm.wrap_objid[w]); }
    for (const jid of joints) if (!tendonOf.has(jid)) tendonOf.set(jid, { a, coef });
  }
  for (const j of model.joints) {
    j.jid = mj.mj_name2id(mjm, OBJ_JOINT, j.name);
    j.qadr = j.jid >= 0 ? mjm.jnt_qposadr[j.jid] : -1;
    j.dadr = j.jid >= 0 ? mjm.jnt_dofadr[j.jid] : -1;
    j.aid = j.jid >= 0 ? actuatorOf.get(j.jid) ?? -1 : -1;
    j.tendon = 0;
    if (j.aid < 0 && tendonOf.has(j.jid)) { j.aid = tendonOf.get(j.jid).a; j.tendon = tendonOf.get(j.jid).coef; }
    // Servo de posición (ctrl = objetivo) o motor de fuerza (el PD se calcula aquí).
    j.servo = j.aid >= 0 && !j.tendon && mjm.actuator_biastype[j.aid] === 1;
    if (j.aid >= 0) {
      j.gear = mjm.actuator_gear[j.aid * 6] || 1;
      if (j.servo) { j.kp = mjm.actuator_gainprm[j.aid * 10]; j.kd = -mjm.actuator_biasprm[j.aid * 10 + 2]; }
      if (mjm.actuator_forcelimited[j.aid]) j.fmax = mjm.actuator_forcerange[j.aid * 2 + 1];
    }
  }
  for (const o of objects) {
    o.body = mj.mj_name2id(mjm, OBJ_BODY, `cu_obj_${o.id}`);
    const jid = mj.mj_name2id(mjm, OBJ_JOINT, `cu_obj_${o.id}`);
    o.qadr = jid >= 0 ? mjm.jnt_qposadr[jid] : -1;
    o.dadr = jid >= 0 ? mjm.jnt_dofadr[jid] : -1;
  }
  const robotBodies = new Set([...model.links.values()].map((l) => l.body).filter((b) => b > 0));
  model.robotGeoms = [];
  for (let g = 0; g < mjm.ngeom; g++) if (robotBodies.has(mjm.geom_bodyid[g])) model.robotGeoms.push(g);
  model.bodyLink = new Map([...model.links.values()].filter((l) => l.body >= 0).map((l) => [l.body, l.name]));
  model.mass = [...robotBodies].reduce((m, b) => m + mjm.body_mass[b], 0);
}

function applyPhysics() {
  if (!mjm) return;
  mjm.opt.gravity[2] = -params.gravity;
  mjm.opt.timestep = params.timestep;
  mjm.opt.iterations = Math.max(1, Math.round(params.iterations));
  // Rebote: MuJoCo no tiene restitución; se aproxima con la amortiguación del contacto (menos, más rebote).
  const dampratio = Math.max(0.1, 1 - params.restitution);
  for (let g = 0; g < mjm.ngeom; g++) { mjm.geom_friction[g * 3] = params.friction; mjm.geom_solref[g * 2 + 1] = dampratio; }
  // Choques del robot consigo mismo (solo en los armados desde URDF; un MJCF trae sus propias reglas).
  if (model && !model.native) {
    for (const g of model.robotGeoms || []) mjm.geom_conaffinity[g] = params.selfCollision ? SELF_BITS : ROBOT_BITS.conaffinity;
  }
}

// ---------- coordenadas de las articulaciones ----------
function readJoints() {
  for (const j of model?.joints || []) {
    if (j.qadr < 0) continue;
    j.q = mjd.qpos[j.qadr];
    j.qd = mjd.qvel[j.dadr];
    j.force = j.aid >= 0 ? mjd.actuator_force[j.aid] * j.gear : mjd.qfrc_actuator[j.dadr];
  }
}

function gauss() { let u = 0, v = 0; while (!u) u = Math.random(); while (!v) v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); }

/** El objetivo de cada actuador, con el ruido de control si está activo (como el de MuJoCo). */
function drive(j) {
  if (!j.driven || j.aid < 0) return;
  let target = j.lower != null ? clamp(j.target, j.lower, j.upper) : j.target;
  if (params.noiseScale > 0) {
    const span = j.lower != null ? j.upper - j.lower : (j.type === "prismatic" ? 0.2 : Math.PI);
    const rate = Math.max(params.noiseRate, params.timestep);
    const a = Math.exp(-params.timestep / rate);
    j.noise = a * (j.noise || 0) + Math.sqrt(1 - a * a) * params.noiseScale * gauss();
    target += j.noise * span / 2;
    if (j.lower != null) target = clamp(target, j.lower, j.upper);
  } else j.noise = 0;
  if (j.servo) { mjd.ctrl[j.aid] = target; return; }
  if (j.tendon) {
    // Por tendón: el largo que da este objetivo (con las acopladas igual) y el control que lo sostiene
    // (fuerza = g·ctrl + b0 + b1·largo, cero en el equilibrio).
    const a = j.aid, g = mjm.actuator_gainprm[a * 10], b0 = mjm.actuator_biasprm[a * 10], b1 = mjm.actuator_biasprm[a * 10 + 1];
    if (!g || !b1) return;
    let ctrl = -(b0 + b1 * target * j.tendon) / g;
    if (mjm.actuator_ctrllimited[a]) ctrl = clamp(ctrl, mjm.actuator_ctrlrange[a * 2], mjm.actuator_ctrlrange[a * 2 + 1]);
    mjd.ctrl[a] = ctrl;
    return;
  }
  // Motor de fuerza: PD con fuerza máxima.
  const force = clamp(j.kp * (target - mjd.qpos[j.qadr]) - j.kd * mjd.qvel[j.dadr], -j.fmax, j.fmax);
  mjd.ctrl[j.aid] = force / j.gear;
}

// ---------- escena ----------
function clearScene() {
  skills.cancel("the robot was reloaded");
  for (const l of model?.links.values() || []) root.remove(l.group);
  for (const o of objects) root.remove(o.mesh);
  for (const c of cameras) c.cam.parent?.remove(c.cam);
  model = null; objects = []; cameras = []; activeCamera = null;
  mjd?.delete(); mjm?.delete(); mjd = null; mjm = null;
}

function objectState(o) {
  if (o.body < 0 || !mjd) return null;
  const p = mjd.xpos, q = mjd.xquat, b = o.body;
  return { pos: [p[b * 3], p[b * 3 + 1], p[b * 3 + 2]], quat: [q[b * 4 + 1], q[b * 4 + 2], q[b * 4 + 3], q[b * 4]] };
}

function setObjectState(o, s) {
  if (o.qadr < 0 || !s) return;
  mjd.qpos.set([...s.pos, s.quat[3], s.quat[0], s.quat[1], s.quat[2]], o.qadr);
  for (let i = 0; i < 6; i++) mjd.qvel[o.dadr + i] = 0;
}

function makeObject(spec) {
  const o = { id: spec.id ?? nextObjectId++, shape: spec.shape || "box", size: spec.size || [0.05, 0.05, 0.05],
    mass: spec.mass ?? 0.05, color: spec.color || "#c8a27a", pos: spec.pos || [0.2, 0, 0.1], yaw: spec.yaw || 0,
    euler: Array.isArray(spec.euler) ? spec.euler : null, parts: Array.isArray(spec.parts) && spec.parts.length ? spec.parts : null,
    fixed: !!spec.fixed, name: spec.name || "", body: -1, qadr: -1, dadr: -1 };
  nextObjectId = Math.max(nextObjectId, o.id + 1);
  // Sin posición (o con drop): se suelta desde un poco más arriba, en un lugar libre.
  if (spec.drop || !spec.pos) o.pos = dropPosition(o);
  o.mesh = new THREE.Group();
  for (const p of partsOf(o)) {
    let geo;
    if (p.shape === "sphere") geo = new THREE.SphereGeometry(p.size[0], 32, 16);
    else if (p.shape === "cylinder") geo = new THREE.CylinderGeometry(p.size[0], p.size[0], p.size[1] ?? p.size[0], 40).rotateX(Math.PI / 2);
    else if (p.shape === "capsule") geo = new THREE.CapsuleGeometry(p.size[0], p.size[1] ?? p.size[0], 8, 24).rotateX(Math.PI / 2);
    else geo = new THREE.BoxGeometry(p.size[0], p.size[1] ?? p.size[0], p.size[2] ?? p.size[0]);
    const mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: p.color, roughness: 0.6, metalness: 0.05 }));
    mesh.position.set(...p.pos);
    mesh.quaternion.set(...quatFromEuler(p.euler));
    mesh.castShadow = mesh.receiveShadow = true;
    mesh.userData.obj = o;
    o.mesh.add(mesh);
  }
  // Medidas en su propio marco (sin el giro del objeto): para el contorno, la zona de agarre y la etiqueta.
  const local = bounds({ ...o, euler: null, yaw: 0 });
  o.dims = local.half.map((h) => h * 2);
  const center = new THREE.Vector3(...local.center);
  // Contorno: una caja de líneas que aparece al pasar el cursor o al agarrarlo.
  const box = new THREE.BoxGeometry(...o.dims.map((d) => d + 0.004));
  o.outline = new THREE.LineSegments(new THREE.EdgesGeometry(box), new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.85, depthTest: false }));
  o.outline.position.copy(center);
  o.outline.renderOrder = 10;
  o.outline.visible = false;
  o.outline.raycast = () => {};   // las líneas no se agarran (su umbral de clic abarcaría toda la escena)
  o.mesh.add(o.outline);
  // Zona de agarre invisible, más grande que el objeto: lo chico (un cubo de 3 cm) se agarra fácil.
  const grip = o.dims.map((d) => Math.max(d + 0.03, 0.06));
  const proxy = new THREE.Mesh(new THREE.BoxGeometry(...grip), new THREE.MeshBasicMaterial({ visible: false }));
  proxy.position.copy(center);
  proxy.userData.obj = o;
  o.mesh.add(proxy);
  o.mesh.position.set(...o.pos);
  o.mesh.quaternion.set(...objectQuat(o));
  o.mesh.userData.obj = o;
  root.add(o.mesh);
  objects.push(o);
  return o;
}

/**
 * Dónde soltar un objeto nuevo: delante del robot, sin encimarse con los otros objetos ni con la base, y
 * con su parte de abajo unos centímetros sobre el piso para que caiga y se acomode solo. Los grandes
 * (un escritorio) van más lejos, fuera del alcance del brazo.
 */
function dropPosition(o) {
  const b = bounds(o);
  const r = b.radius;
  const base = 0.12;   // lo que ocupa la base del robot
  const taken = objects.map((x) => {
    const p = objectState(x)?.pos || x.pos;
    return { x: p[0], y: p[1], r: bounds(x).radius };
  });
  const free = (x, y) => Math.hypot(x, y) > base + r && taken.every((t) => Math.hypot(x - t.x, y - t.y) > t.r + r + 0.01);
  const z = b.half[2] - b.center[2] + 0.04;
  for (let d = Math.max(0.2, base + r + 0.02); d < 4; d += Math.max(0.03, r / 2)) {
    for (const deg of [0, 20, -20, 40, -40, 60, -60, 90, -90]) {
      const a = (deg + (Math.random() - 0.5) * 8) * Math.PI / 180;
      const x = Math.cos(a) * d, y = Math.sin(a) * d;
      if (free(x, y)) return [x, y, z];
    }
  }
  return [0.3, 0, z];
}

function addObject(spec) {
  const o = makeObject(spec);
  if (mjm) { compileScene(); sync(); }
  return o.id;
}

/**
 * Cambia un objeto ya puesto: dónde está (pos, m), su giro (euler o yaw, grados), su peso, color, nombre o si
 * está fijo. Mover o girar lo deja quieto en el lugar nuevo (y la física sigue desde ahí); lo demás lo rearma.
 */
function updateObject(id, changes = {}) {
  const o = objects.find((x) => x.id === id);
  if (!o) return false;
  const now = objectState(o);
  const turned = "euler" in changes || "yaw" in changes;
  const spec = {
    id: o.id, shape: o.shape, size: o.size, mass: o.mass, color: o.color, yaw: o.yaw, euler: o.euler, parts: o.parts,
    fixed: o.fixed, name: o.name, pos: now?.pos || o.pos, ...changes, drop: false,
  };
  // Un color nuevo pinta todas las piezas.
  if ("color" in changes && spec.parts) spec.parts = spec.parts.map((p) => ({ ...p, color: changes.color }));
  const index = objects.indexOf(o);
  root.remove(o.mesh);
  objects.splice(index, 1);
  const n = makeObject(spec);
  objects.splice(objects.indexOf(n), 1);
  objects.splice(index, 0, n);   // mismo lugar en la lista
  if (hovered === o) hovered = n;
  if (selected === o) selected = n;
  if (drag?.obj === o) drag = null;
  if (mjm) {
    compileScene();
    // Si no se pidió otro giro, conserva el que tenía (p. ej. un cubo caído de costado).
    if (!turned && now) setObjectState(n, { pos: n.pos, quat: now.quat });
    mj.mj_forward(mjm, mjd);
    sync();
  }
  return true;
}

function removeObject(id) {
  const o = objects.find((x) => x.id === id);
  if (!o) return;
  root.remove(o.mesh);
  if (hovered === o) hovered = null;
  if (selected === o) selected = null;
  if (drag?.obj === o) drag = null;
  objects = objects.filter((x) => x !== o);
  if (mjm) { compileScene(); sync(); }
}

function addCamera(spec) {
  const link = model?.links.get(spec.link);
  if (!link) return;  // la cámara va en una pieza que este modelo no tiene
  const cam = new THREE.PerspectiveCamera(spec.fovy || 60, (spec.width || 640) / (spec.height || 480), 0.005, 20);
  // Pose dentro del link (convención de MuJoCo: mira hacia −z, y hacia arriba). quat [x,y,z,w] o rpy.
  const q = spec.quat ? new THREE.Quaternion(...spec.quat) : quatRPY(spec.rpy || [0, 0, 0]);
  const holder = new THREE.Group();   // el grupo de la pieza ya está en su marco
  cam.position.set(...(spec.pos || [0, 0, 0]));
  cam.quaternion.copy(q);
  holder.add(cam);
  link.group.add(holder);
  cameras.push({ ...spec, cam });
}

// ---------- paso de simulación ----------
function physicsStep() {
  const t0 = performance.now();
  skills.tick(params.timestep);
  for (const j of model?.joints || []) drive(j);
  pullDragged();
  mj.mj_step(mjm, mjd);
  stepMs = 0.98 * stepMs + 0.02 * (performance.now() - t0);
  simTime = mjd.time;
}

function sync() {
  if (!mjd) return;
  const p = mjd.xpos, q = mjd.xquat;
  for (const l of model?.links.values() || []) {
    const b = l.body;
    if (b < 0) { l.group.visible = false; continue; }
    l.group.position.set(p[b * 3], p[b * 3 + 1], p[b * 3 + 2]);
    l.group.quaternion.set(q[b * 4 + 1], q[b * 4 + 2], q[b * 4 + 3], q[b * 4]);
  }
  for (const o of objects) {
    const b = o.body;
    if (b < 0) continue;
    o.mesh.position.set(p[b * 3], p[b * 3 + 1], p[b * 3 + 2]);
    o.mesh.quaternion.set(q[b * 4 + 1], q[b * 4 + 2], q[b * 4 + 3], q[b * 4]);
  }
  readJoints();
}

const MAX_MARKERS = 256;
function updateContacts() {
  let n = 0, maxForce = 0;
  const linkForce = {}, color = new THREE.Color(), m4 = new THREE.Matrix4();
  const count = Math.min(mjd.ncon, MAX_MARKERS);
  if (count) {
    const list = mjd.contact;
    forceBuf ??= new mj.DoubleBuffer(6);
    for (let i = 0; i < count; i++) {
      const c = list.get(i);
      mj.mj_contactForce(mjm, mjd, i, forceBuf);
      const force = Math.abs(forceBuf.GetView()[0]);
      maxForce = Math.max(maxForce, force);
      for (const g of [c.geom1, c.geom2]) {
        const link = model.bodyLink.get(mjm.geom_bodyid[g]);
        if (link) linkForce[link] = (linkForce[link] || 0) + force;
      }
      const pos = c.pos;
      markers.setMatrixAt(n, m4.makeTranslation(pos[0], pos[1], pos[2]));
      markers.setColorAt(n, color.setHSL(0.33 * (1 - clamp(force / 5, 0, 1)), 0.85, 0.5));
      n++;
      c.delete?.();
    }
    list.delete();
  }
  markers.count = n;
  markers.instanceMatrix.needsUpdate = true;
  if (markers.instanceColor) markers.instanceColor.needsUpdate = true;
  readout = { contacts: mjd.ncon, maxForce, links: linkForce };
}

function postState(now) {
  if (now - lastPost < 100) return;
  lastPost = now;
  post({
    type: "state", t: simTime, rtf, paused, mode, stepMs,
    joints: (model?.joints || []).map((j) => ({ name: j.name, q: j.q, qd: j.qd, target: j.target, force: j.force })),
    contacts: readout.contacts, maxForce: readout.maxForce,
    links: Object.entries(readout.links).map(([name, force]) => ({ name, force })),
    objects: objects.map((o) => ({ id: o.id, pos: objectState(o)?.pos || o.pos })),
  });
}

function frame(now) {
  const dtWall = Math.min(0.1, (now - (wallLast || now)) / 1000);
  wallLast = now;
  if (mjd && model && !paused) {
    accum += dtWall * speed;
    const t0 = simTime, start = performance.now();
    while (accum >= params.timestep && performance.now() - start < 25) { physicsStep(); accum -= params.timestep; }
    if (accum > params.timestep * 4) accum = 0;  // no alcanza: se desacelera en vez de acumular
    rtf = dtWall > 0 ? 0.9 * rtf + 0.1 * ((simTime - t0) / dtWall) : rtf;
  } else rtf = 0;
  if (paused && drag) pullDragged();
  if (mjd) { sync(); if (render.contacts) updateContacts(); else { markers.count = 0; readout = { contacts: mjd.ncon, maxForce: 0, links: {} }; } }
  controls.update();
  updateObjectLabel();
  renderer.render(scene, camera);
  renderPip();
  postState(now);
}

// ---------- cámara de una cámara montada (cuadro en la esquina) ----------
function renderPip() {
  const pip = document.getElementById("pip");
  const c = cameras.find((x) => x.name === activeCamera);
  pip.hidden = !c;
  if (!c) return;
  if (!pipRenderer) {
    pipRenderer = new THREE.WebGLRenderer({ canvas: document.getElementById("pipCanvas"), antialias: true });
    pipRenderer.outputColorSpace = THREE.SRGBColorSpace;
  }
  const w = 240, h = Math.round(240 * c.cam.aspect ** -1);
  pipRenderer.setSize(w, h, false);
  pipRenderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  markers.visible = false;
  pipRenderer.render(scene, c.cam);
  markers.visible = true;
  document.getElementById("pipLabel").textContent = c.name;
}

// ---------- agarrar objetos con el mouse ----------
// Clic sobre un objeto: se levanta unos centímetros y sigue al cursor sobre el plano horizontal; la rueda
// del mouse lo sube o lo baja. Al soltar, cae con la física. Lo sostiene un resorte amortiguado sobre su
// centro (como agarrarlo con la mano), así que choca y empuja como cualquier cosa. En pausa, se mueve sin física.
const raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2();
let drag = null, hoverAt = 0;
const LIFT = 0.04;
function rayFrom(e) {
  const r = renderer.domElement.getBoundingClientRect();
  pointer.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(pointer, camera);
}
function objectAt(e) {
  rayFrom(e);
  const hit = raycaster.intersectObjects(objects.filter((o) => !o.fixed).map((o) => o.mesh), true)[0];
  return hit?.object.userData.obj ? { obj: hit.object.userData.obj, point: hit.point } : null;
}
// Con el mouse: arrastrar un objeto lo lleva (la rueda lo sube o baja; Shift + rueda lo gira), Q / E lo giran de a
// 15° (al agarrado o al seleccionado) y un clic sin arrastrar lo selecciona, para que la app lo abra en su lista.
const TURN_STEP = Math.PI / 12;
let selected = null;
function select(o) {
  selected = o;
  post({ type: "select", id: o?.id ?? null });
}
function onPointerDown(e) {
  if (e.button !== 0 || e.altKey || e.metaKey || e.ctrlKey || !mjd) return;
  const hit = objectAt(e);
  if (!hit || hit.obj.body < 0) {
    // En vacío: si termina siendo un clic (no un giro de cámara), quita la selección.
    const at = { x: e.clientX, y: e.clientY };
    window.addEventListener("pointerup", (u) => { if (Math.hypot(u.clientX - at.x, u.clientY - at.y) < 5 && selected) select(null); }, { once: true });
    return;
  }
  e.stopPropagation();
  controls.enabled = false;
  const b = hit.obj.body;
  // El punto agarrado y el centro del objeto, en el marco del robot (z arriba).
  const grab = root.worldToLocal(hit.point.clone());
  const com = new THREE.Vector3(mjd.xpos[b * 3], mjd.xpos[b * 3 + 1], mjd.xpos[b * 3 + 2]);
  drag = { obj: hit.obj, offset: com.clone().sub(grab), height: grab.z + LIFT, target: grab.clone().setZ(grab.z + LIFT) };
  if (selected !== hit.obj) select(hit.obj);
  renderer.domElement.style.cursor = "grabbing";
  window.addEventListener("pointermove", onDragMove);
  window.addEventListener("wheel", onDragWheel, { passive: false });
  window.addEventListener("pointerup", endDrag, { once: true });
}
function onDragMove(e) {
  if (!drag) return;
  rayFrom(e);
  // El plano horizontal a la altura de agarre, pasado a coordenadas de three.js (y arriba).
  const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), -drag.height);
  const hit = new THREE.Vector3();
  if (raycaster.ray.intersectPlane(plane, hit)) drag.target = root.worldToLocal(hit).setZ(drag.height);
}
function onDragWheel(e) {
  if (!drag) return;
  e.preventDefault();
  if (e.shiftKey) {
    // Con Shift, la rueda gira el objeto alrededor de la vertical (el desplazamiento puede llegar en x).
    turnObject(drag.obj, -(e.deltaY || e.deltaX) * 0.004);
    return;
  }
  drag.height = Math.max(0.005, drag.height - e.deltaY * 0.0006);
  drag.target.z = drag.height;
}
function endDrag() {
  hovered = drag?.obj ?? hovered;
  drag = null;
  controls.enabled = true;
  renderer.domElement.style.cursor = "";
  window.removeEventListener("pointermove", onDragMove);
  window.removeEventListener("wheel", onDragWheel);
}
/** Gira un objeto `angle` radianes alrededor de la vertical, sin moverlo de lugar (quieto o con física). */
function turnObject(o, angle) {
  if (!o || o.qadr < 0 || !mjd) return;
  const a = o.qadr + 3;
  const q = new THREE.Quaternion(mjd.qpos[a + 1], mjd.qpos[a + 2], mjd.qpos[a + 3], mjd.qpos[a]);
  q.premultiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), angle)).normalize();
  mjd.qpos[a] = q.w; mjd.qpos[a + 1] = q.x; mjd.qpos[a + 2] = q.y; mjd.qpos[a + 3] = q.z;
  for (let i = 3; i < 6; i++) mjd.qvel[o.dadr + i] = 0;
  mj.mj_forward(mjm, mjd);
}
function onKeyDown(e) {
  if (e.metaKey || e.ctrlKey || e.altKey || /input|textarea|select/i.test(e.target?.tagName ?? "")) return;
  const key = e.key.toLowerCase();
  if (key !== "q" && key !== "e") return;
  const o = drag?.obj ?? selected;
  if (!o) return;
  e.preventDefault();
  turnObject(o, key === "q" ? TURN_STEP : -TURN_STEP);
}
/** El cursor de mano y el contorno de lo que se puede agarrar. */
let hovered = null;
function onHover(e) {
  if (drag || !mjd || performance.now() - hoverAt < 40) return;
  hoverAt = performance.now();
  const hit = objectAt(e);
  hovered = hit?.obj ?? null;
  renderer.domElement.style.cursor = hovered ? "grab" : "";
}
function onLeave() { if (!drag) hovered = null; }

const fmtLen = (m) => (m >= 1 ? `${+m.toFixed(2)} m` : `${+(m * 100).toFixed(m < 0.1 ? 1 : 0)}`);
const fmtMass = (kg) => (kg >= 1 ? `${+kg.toFixed(kg >= 10 ? 0 : 1)} kg` : `${Math.round(kg * 1000)} g`);
const OBJ_NAMES = { box: "Box", sphere: "Sphere", cylinder: "Cylinder", capsule: "Capsule" };
/** En cada paso de física: la fuerza que lleva el objeto agarrado hacia el cursor (resorte + amortiguador). */
function pullDragged() {
  for (const o of objects) if (o.pulled) { for (let i = 0; i < 6; i++) mjd.xfrc_applied[o.body * 6 + i] = 0; o.pulled = false; }
  if (!drag || drag.obj.body < 0 || !mjd) return;
  const o = drag.obj, b = o.body, m = mjm.body_subtreemass?.[b] || mjm.body_mass[b];
  const goal = drag.target.clone().add(drag.offset);
  if (paused) {
    // Sin física: se lleva directo (y queda quieto donde se suelte hasta seguir).
    const s = objectState(o);
    if (s) { setObjectState(o, { pos: [goal.x, goal.y, goal.z], quat: s.quat }); mj.mj_forward(mjm, mjd); }
    return;
  }
  const w = 14, k = m * w * w, c = 2 * m * w;      // críticamente amortiguado
  // Velocidad del objeto: la de su articulación libre (avance en el marco del mundo, giro en el suyo).
  const lin = (i) => (o.dadr >= 0 ? mjd.qvel[o.dadr + i] : 0), ang = (i) => (o.dadr >= 0 ? mjd.qvel[o.dadr + 3 + i] : 0);
  const pos = [mjd.xipos[b * 3], mjd.xipos[b * 3 + 1], mjd.xipos[b * 3 + 2]];
  const goalArr = [goal.x, goal.y, goal.z];
  const fmax = m * (params.gravity + 60);
  for (let i = 0; i < 3; i++) {
    const force = k * (goalArr[i] - pos[i]) - c * lin(i) + (i === 2 ? m * params.gravity : 0);
    mjd.xfrc_applied[b * 6 + i] = Math.max(-fmax, Math.min(fmax, force));
  }
  // Frena el giro para que no quede dando vueltas colgado del cursor.
  const inertia = (mjm.body_inertia[b * 3] + mjm.body_inertia[b * 3 + 1] + mjm.body_inertia[b * 3 + 2]) / 3;
  const q = new THREE.Quaternion(mjd.xquat[b * 4 + 1], mjd.xquat[b * 4 + 2], mjd.xquat[b * 4 + 3], mjd.xquat[b * 4]);
  const spin = new THREE.Vector3(ang(0), ang(1), ang(2)).applyQuaternion(q);   // al marco del mundo
  mjd.xfrc_applied[b * 6 + 3] = -inertia * 40 * spin.x;
  mjd.xfrc_applied[b * 6 + 4] = -inertia * 40 * spin.y;
  mjd.xfrc_applied[b * 6 + 5] = -inertia * 40 * spin.z;
  o.pulled = true;
}

/** Cada cuadro: el contorno del objeto señalado y su etiqueta (nombre, medidas y peso) encima. */
function updateObjectLabel() {
  const target = drag?.obj ?? hovered ?? selected;
  for (const o of objects) o.outline.visible = o === target || o === selected;
  const el = document.getElementById("objLabel");
  if (!target || !objects.includes(target)) { el.hidden = true; return; }
  const top = new THREE.Box3().setFromObject(target.outline);
  const p = new THREE.Vector3((top.min.x + top.max.x) / 2, top.max.y, (top.min.z + top.max.z) / 2).project(camera);
  const r = renderer.domElement.getBoundingClientRect();
  const [a, b, c] = target.dims;
  const big = Math.max(a, b, c) >= 1;
  const size = big ? `${fmtLen(a)} × ${fmtLen(b)} × ${fmtLen(c)}` : `${fmtLen(a)} × ${fmtLen(b)} × ${fmtLen(c)} cm`;
  el.innerHTML = "";
  el.append(target.name || OBJ_NAMES[target.shape] || "Object");
  const detail = document.createElement("span");
  detail.textContent = `  ${size} · ${fmtMass(target.mass)}`;
  el.append(detail);
  el.style.left = `${((p.x + 1) / 2) * r.width}px`;
  el.style.top = `${((1 - p.y) / 2) * r.height}px`;
  el.hidden = p.z > 1;
}

// ---------- vistas ----------
function frameModel(view = "tres") {
  const box = new THREE.Box3();
  for (const l of model?.links.values() || []) box.expandByObject(l.group);
  if (box.isEmpty()) box.setFromCenterAndSize(new THREE.Vector3(), new THREE.Vector3(0.5, 0.5, 0.5));
  const center = box.getCenter(new THREE.Vector3()), size = box.getSize(new THREE.Vector3()).length() || 0.5;
  const d = size * 2.1;
  const dirs = { tres: [1, 0.8, 1], frente: [0, 0.3, 1], lado: [1, 0.3, 0], arriba: [0.001, 1, 0.001] };
  const v = new THREE.Vector3(...(dirs[view] || dirs.tres)).normalize().multiplyScalar(d);
  controls.target.copy(center);
  camera.position.copy(center).add(v);
  camera.near = size / 200; camera.far = size * 200;
  resize();
}

// ---------- tamaño y centro óptico ----------
/** Corre el centro de la imagen a la izquierda para que el robot quede en el área que no tapa el panel. */
function resize() {
  const canvas = renderer.domElement, w = canvas.clientWidth, h = Math.max(canvas.clientHeight, 1);
  renderer.setSize(w, h, false);
  const d = Math.min(insetRight / 2, w / 3);
  camera.aspect = (w + 2 * d) / h;
  if (d > 0) camera.setViewOffset(w + 2 * d, h, 2 * d, 0, w, h); else camera.clearViewOffset();
  camera.updateProjectionMatrix();
}

// ---------- arranque ----------
function setup() {
  const canvas = document.getElementById("view");
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  scene = new THREE.Scene();
  scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
  camera = new THREE.PerspectiveCamera(40, 1, 0.005, 50);
  camera.position.set(0.6, 0.45, 0.6);
  controls = new OrbitControls(camera, canvas);
  controls.enableDamping = true;
  root = new THREE.Group();
  root.rotation.x = -Math.PI / 2;  // z-arriba (URDF) → y-arriba (three.js)
  scene.add(root);
  const sun = new THREE.DirectionalLight(0xffffff, 1.6);
  sun.position.set(1.5, 3, 1.2);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  Object.assign(sun.shadow.camera, { left: -2, right: 2, top: 2, bottom: -2, near: 0.1, far: 10 });
  scene.add(sun, new THREE.HemisphereLight(0xffffff, 0x444444, 0.4));
  ground = new THREE.Mesh(new THREE.PlaneGeometry(10, 10), new THREE.ShadowMaterial({ opacity: 0.22 }));
  ground.receiveShadow = true;
  root.add(ground);
  grid = new THREE.GridHelper(4, 80, 0x888888, 0x888888);
  grid.rotation.x = Math.PI / 2;
  grid.material.transparent = true;
  grid.material.opacity = 0.18;
  root.add(grid);
  markers = new THREE.InstancedMesh(new THREE.SphereGeometry(0.003, 8, 6), new THREE.MeshBasicMaterial(), MAX_MARKERS);
  markers.count = 0;
  root.add(markers);
  canvas.addEventListener("pointerdown", onPointerDown, { capture: true });
  window.addEventListener("keydown", onKeyDown);
  canvas.addEventListener("pointermove", onHover);
  canvas.addEventListener("pointerleave", onLeave);
  new ResizeObserver(resize).observe(canvas);
  resize();
  renderer.setAnimationLoop(frame);
}

/** Cuadrícula con coordenadas en píxeles, para que la IA pueda señalar con precisión. */
function drawGrid(ctx, w, h, step = 64) {
  ctx.save();
  ctx.lineWidth = 1;
  ctx.font = "11px -apple-system, sans-serif";
  ctx.textBaseline = "top";
  for (let x = step; x < w; x += step) {
    ctx.strokeStyle = "rgba(255,255,255,0.35)";
    ctx.beginPath(); ctx.moveTo(x + 0.5, 0); ctx.lineTo(x + 0.5, h); ctx.stroke();
    ctx.fillStyle = "rgba(0,0,0,0.6)"; ctx.fillRect(x + 2, 2, 26, 13);
    ctx.fillStyle = "#fff"; ctx.fillText(String(x), x + 4, 3);
  }
  for (let y = step; y < h; y += step) {
    ctx.strokeStyle = "rgba(255,255,255,0.35)";
    ctx.beginPath(); ctx.moveTo(0, y + 0.5); ctx.lineTo(w, y + 0.5); ctx.stroke();
    ctx.fillStyle = "rgba(0,0,0,0.6)"; ctx.fillRect(2, y + 2, 26, 13);
    ctx.fillStyle = "#fff"; ctx.fillText(String(y), 4, y + 3);
  }
  ctx.restore();
}

// ---------- API para la app ----------
let currentLoad = null, loadQueue = Promise.resolve();
window.studio = {
  /** Las cargas van en fila (una no puede borrar el mundo mientras otra lo arma) y se salta la que ya quedó vieja. */
  load(args) {
    const token = (currentLoad = {});
    loadQueue = loadQueue.then(() => (token === currentLoad ? this.loadNow(args, token) : null));
    return loadQueue;
  },
  async loadNow({ url, profile = {} }, token) {
    try {
      post({ type: "loading", text: "Reading the model…" });
      const res = await fetch(url);
      if (!res.ok) throw new Error(`Couldn't read ${url}`);
      const text = await res.text();
      const native = /<mujoco[\s>]/.test(text);
      const im = native ? await parseMJCF(text, url) : parseURDF(text);
      if (token !== currentLoad) return;
      clearScene();
      Object.assign(params, profile.physics || {});
      simTime = 0;
      post({ type: "loading", text: `Building ${im.links.filter((l) => !l.virtual).length} links…` });
      const built = await buildModel(im, url.slice(0, url.lastIndexOf("/")), profile, native);
      if (token !== currentLoad) return;
      model = built;
      for (const l of model.links.values()) root.add(l.group);

      // Al sistema de archivos de MuJoCo: el MJCF con sus archivos, o el armado desde el URDF.
      if (files) rmTree(files.dir);
      const dir = `/model/${++loadCount}`;
      mkdirs(dir);
      if (native) {
        const name = url.slice(url.lastIndexOf("/") + 1);
        mj.FS.writeFile(fsPath(dir, name), text);
        await writeMJCF(text, url, dir);
        files = { dir, robot: name };
      } else {
        mj.FS.writeFile(fsPath(dir, "cu_robot.xml"), robotXML(im, model.rootLink, model.shapes, model.gains, params));
        files = { dir, robot: "cu_robot.xml" };
      }
      if (token !== currentLoad) return;
      post({ type: "loading", text: "Compiling with MuJoCo…" });
      for (const o of profile.scene?.objects || []) makeObject(o);
      compileScene();

      for (const c of [...(im.cameras || []), ...(profile.cameras || [])]) addCamera(c);
      effectorConfig = profile.effector || null;
      homeTargets = { ...(im.home || {}), ...(profile.home || {}) };
      this.reset(true);
      // Una cámara fija sobre la mesa, como la del robot real, si el perfil no trae ninguna fija: encima de la
      // zona de trabajo de este brazo y a una altura según su alcance (sirve para un brazo chico o uno grande).
      if (!cameras.some((c) => c.link === model.rootLink)) {
        let pos = [0.2, 0, 0.55];
        try {
          const w = skills.workspace(0);
          const x = Math.cos(w.azimuth) * w.distance, y = Math.sin(w.azimuth) * w.distance;
          pos = [w.base[0] + x, w.base[1] + y, w.base[2] + Math.max(0.45, 2.4 * w.distance)];
        } catch { /* sin brazo reconocible: la posición de siempre */ }
        addCamera({ name: "Overhead", link: model.rootLink, pos, quat: [0, 0, 0, 1], fovy: 60, width: 640, height: 480 });
      }
      applyRender();
      frameModel();
      post({
        type: "model", name: model.name, root: model.rootLink,
        links: [...model.links.values()].filter((l) => !l.virtual).map((l) => l.name),
        joints: model.joints.map((j) => ({ name: j.name, type: j.type, parent: j.parent, child: j.child,
          lower: j.lower, upper: j.upper, effort: j.effort, velocity: j.velocity, kp: j.kp, kd: j.kd, fmax: j.fmax,
          actuated: j.actuated, mimic: j.mimic?.joint ?? null })),
        floating: model.floating,
        fixedJoints: im.joints.filter((j) => j.type === "fixed").length,
        mass: model.mass,
        cameras: cameras.map((c) => c.name),
        objects: objects.map(({ id, shape, size, mass, color, pos, yaw, euler, parts, fixed, name }) => ({ id, shape, size, mass, color, pos, yaw, euler, parts, fixed, name })),
        physics: { ...params },
        warnings: built.warnings,
      });
    } catch (e) {
      post({ type: "error", text: typeof e === "number" ? "MuJoCo couldn't compile the model." : e.message });
    }
  },
  setTarget(name, value) { const j = model?.joints.find((x) => x.name === name); if (j?.actuated) j.target = value; },
  /** q: {articulación: valor}. snap: además coloca el robot ahí de golpe (para keyframes). */
  setTargets(q, snap = false) {
    for (const j of model?.joints || []) if (q[j.name] != null) j.target = q[j.name];
    if (snap) this.reset(false);
  },
  setGains(name, { kp, kd, fmax }) {
    const j = model?.joints.find((x) => x.name === name);
    if (!j) return;
    if (kp != null) j.kp = kp;
    if (kd != null) j.kd = kd;
    if (fmax != null) j.fmax = fmax;
    if (mjm && j.aid >= 0 && j.servo) {
      const a = j.aid;
      mjm.actuator_gainprm[a * 10] = j.kp;
      mjm.actuator_biasprm[a * 10 + 1] = -j.kp;
      mjm.actuator_biasprm[a * 10 + 2] = -j.kd;
      mjm.actuator_forcelimited[a] = 1;
      mjm.actuator_forcerange[a * 2] = -j.fmax;
      mjm.actuator_forcerange[a * 2 + 1] = j.fmax;
    }
  },
  setPhysics(p) {
    Object.assign(params, p);
    applyPhysics();
  },
  /** Coloca el robot de golpe en sus objetivos (o en la pose de reposo), quieto. Los objetos no se mueven. */
  reset(zeroTargets = true) {
    if (!model || !mjd) return;
    skills.cancel("the robot was reset");
    for (const j of model.joints) {
      if (zeroTargets) j.target = homeTargets[j.name] ?? (j.lower != null ? clamp(0, j.lower, j.upper) : 0);
    }
    for (const j of model.joints) {
      if (j.mimic && j.master) j.target = j.mimic.multiplier * j.master.target + j.mimic.offset;
      if (j.qadr < 0) continue;
      mjd.qpos[j.qadr] = j.lower != null ? clamp(j.target, j.lower, j.upper) : j.target;
      mjd.qvel[j.dadr] = 0;
    }
    // Base libre: vuelve a su pose inicial.
    for (let k = 0; k < mjm.njnt; k++) {
      if (mjm.jnt_type[k] !== 0 || objects.some((o) => o.qadr === mjm.jnt_qposadr[k])) continue;
      const a = mjm.jnt_qposadr[k], d = mjm.jnt_dofadr[k];
      for (let i = 0; i < 7; i++) mjd.qpos[a + i] = mjm.qpos0[a + i];
      for (let i = 0; i < 6; i++) mjd.qvel[d + i] = 0;
    }
    mj.mj_forward(mjm, mjd);
    sync();
  },
  /** Imagen JPEG (data URL) de la vista principal o de una cámara montada, para que la IA «mire». */
  capture(cameraName = null, width = 768, format = "jpeg", grid = false) {
    const c = cameras.find((x) => x.name === cameraName);
    const cam = c ? c.cam : camera;
    const w = width, h = Math.round(width / (c ? c.cam.aspect : camera.aspect));
    const rt = new THREE.WebGLRenderTarget(w, h, { colorSpace: THREE.SRGBColorSpace, samples: 4 });
    markers.visible = false;
    const aspect = cam.aspect;
    renderer.setRenderTarget(rt);
    renderer.render(scene, cam);
    renderer.setRenderTarget(null);
    markers.visible = true;
    cam.aspect = aspect;
    const px = new Uint8Array(w * h * 4);
    renderer.readRenderTargetPixels(rt, 0, 0, w, h, px);
    rt.dispose();
    const canvas = document.createElement("canvas");
    canvas.width = w; canvas.height = h;
    const ctx = canvas.getContext("2d"), img = ctx.createImageData(w, h);
    for (let y = 0; y < h; y++) img.data.set(px.subarray((h - 1 - y) * w * 4, (h - y) * w * 4), y * w * 4);  // WebGL va de abajo arriba
    ctx.fillStyle = "#e9e9e7";
    ctx.fillRect(0, 0, w, h);
    const tmp = document.createElement("canvas");
    tmp.width = w; tmp.height = h;
    tmp.getContext("2d").putImageData(img, 0, 0);
    ctx.drawImage(tmp, 0, 0);
    if (grid) drawGrid(ctx, w, h);
    return format === "png" ? canvas.toDataURL("image/png") : canvas.toDataURL("image/jpeg", 0.8);
  },
  resetObjects(list) {
    for (const o of objects) root.remove(o.mesh);
    objects = [];
    for (const o of list || []) makeObject(o);
    if (mjm) { compileScene(); sync(); }
  },
  addObject(spec) { return addObject(spec); },
  updateObject(id, changes) { return updateObject(id, changes); },
  /** Dónde está y cómo está girado cada objeto ahora (m, grados alrededor de z). */
  objectPoses() {
    return objects.map((o) => {
      const s = objectState(o);
      const q = s ? s.quat : objectQuat(o);
      const yaw = Math.atan2(2 * (q[3] * q[2] + q[0] * q[1]), 1 - 2 * (q[1] * q[1] + q[2] * q[2])) * 180 / Math.PI;
      return { id: o.id, pos: s?.pos || o.pos, yaw };
    });
  },
  removeObject(id) { removeObject(id); },
  addCamera(spec) { addCamera(spec); },
  removeCamera(name) {
    const c = cameras.find((x) => x.name === name);
    c?.cam.parent?.parent?.remove(c.cam.parent);
    cameras = cameras.filter((x) => x !== c);
    if (activeCamera === name) activeCamera = null;
  },
  showCamera(name) { activeCamera = name || null; },
  /** Selecciona un objeto (o ninguno) desde la app: lo marca con su contorno y etiqueta. */
  select(id) { selected = objects.find((o) => o.id === id) ?? null; },
  pause(on) { paused = on; },
  step(n = 1) { if (!mjd || !model) return; for (let i = 0; i < n; i++) physicsStep(); sync(); },
  setSpeed(x) { speed = x; },
  setMode(m) { mode = m; },
  view(name) { frameModel(name); },
  setRender(opts) { Object.assign(render, opts); applyRender(); },
  /** Estado completo (articulaciones y objetos) para un keyframe o para copiarlo. */
  /** Dónde está cada pieza (metros, marco de la base del robot): cinemática directa para la IA. */
  linkPositions() {
    if (!model || !mjd) return {};
    const p = mjd.xpos, rb = model.links.get(model.rootLink)?.body ?? 0;
    return Object.fromEntries([...model.links].filter(([, l]) => l.body >= 0).map(([name, l]) =>
      [name, [0, 1, 2].map((i) => p[l.body * 3 + i] - p[rb * 3 + i])]));
  },
  getKeyframe() {
    return {
      time: simTime,
      q: Object.fromEntries((model?.joints || []).map((j) => [j.name, j.q])),
      objects: objects.map((o) => ({ id: o.id, ...(objectState(o) || { pos: o.pos, quat: [0, 0, 0, 1] }) })),
    };
  },
  setKeyframe(k) {
    if (!model || !k) return;
    for (const j of model.joints) if (k.q?.[j.name] != null) j.target = k.q[j.name];
    this.reset(false);
    for (const s of k.objects || []) {
      const o = objects.find((x) => x.id === s.id);
      if (o) setObjectState(o, s);
    }
    if (mjd) mj.mj_forward(mjm, mjd);
    sync();
  },
  /**
   * Una habilidad que se mueve sola: { type: pick | place | reach | gripper, camera, x, y, width, height, surface, open }.
   * El objetivo sale de un píxel de una cámara (no de dónde están los objetos). Devuelve cómo salió.
   */
  skill(spec) {
    if (!model || !mjd) throw new Error("The robot isn't loaded.");
    const s = { ...spec };
    if (s.camera != null) {
      // Al agarrar se señala la cara de arriba del objeto; al dejar, la superficie donde va.
      const plane = s.type === "pick" ? (s.height ?? 0.025) : (s.surface ?? 0);
      const px = (x, y) => skills.pointFromPixel(s.camera, x, y, s.imageWidth ?? 768, plane);
      if (s.fingers) {
        // Dónde va cada dedo: el medio es el centro del agarre; la línea entre ellos, hacia dónde cierran.
        const [a, b] = s.fingers.map(([x, y]) => px(x, y));
        s.point = a.map((v, i) => (v + b[i]) / 2);
        s.yaw = [b[0] - a[0], b[1] - a[1]];
        s.width = Math.hypot(...s.yaw);
      } else {
        s.point = px(s.x, s.y);
      }
    }
    paused = false;
    return skills.run(s);
  },
  cancelSkill() { skills.cancel("stopped"); },
  /** Lo mismo que skill pero sin mover nada: la trayectoria para que la haga el robot real (ver skills.timeline). */
  planSkill(spec, opts) {
    if (!model || !mjd) throw new Error("The robot isn't loaded.");
    return skills.timeline(spec, opts);
  },
  /** El centro del agarre ahora (m, marco de la base). */
  tip() { return model && mjd ? skills.tip() : null; },
  /** Cambia los límites de las articulaciones (p. ej. los de la calibración del robot real): {nombre: [min, max]}. */
  setLimits(limits) {
    for (const j of model?.joints || []) {
      const l = limits?.[j.name];
      if (l && l.length === 2 && l[0] < l[1]) { j.lower = l[0]; j.upper = l[1]; }
    }
  },
  effector() { return model ? skills.effector() : null; },
  /** El espacio de trabajo del brazo: alcance, hacia dónde mira y puntos alcanzables (m, marco de la base). */
  workspace(count = 8) { return model && mjd ? skills.workspace(count) : null; },
  /** Las cámaras fijas o montadas, con el tamaño de su imagen a `width` de ancho. */
  cameraInfo(width = 768) {
    return cameras.map((c) => ({ name: c.name, link: c.link, fixed: c.link === model?.rootLink, width, height: Math.round(width / c.cam.aspect) }));
  },
  setInsets({ right = 0 }) { if (right !== insetRight) { insetRight = right; resize(); } },
  /** Pose actual, para guardar un keyframe. */
  snapshot() { return Object.fromEntries((model?.joints || []).map((j) => [j.name, j.q])); },
};

try {
  mj = await loadMujoco();
  setup();
  post({ type: "ready" });
} catch (e) {
  post({ type: "error", text: `Couldn't start the engine: ${e.message}` });
}
