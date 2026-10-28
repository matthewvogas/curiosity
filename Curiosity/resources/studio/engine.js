// Motor de simulación de Curiosity Studio. Agnóstico al robot: arma cualquier URDF con física real.
//
// Lo esencial de MuJoCo, sobre Rapier:
//  · Cuerpos rígidos por link, con su masa e inercia (<inertial>) y colisiones convexas (<collision>).
//  · Articulaciones revolute, continuous, prismatic y fixed, con límites (<limit>).
//  · Un actuador de posición por articulación móvil: PD (kp, kd) con fuerza máxima (forcerange).
//  · Contactos con fricción y rebote, gravedad, paso de tiempo y subpasos configurables.
//  · Sensores: posición, velocidad y fuerza de cada articulación; contactos y fuerza por link.
//  · Cámaras montadas en cualquier link, objetos libres en la escena, pausa, paso a paso y velocidad.
//
// Convenciones: el mundo físico es el del URDF (z hacia arriba, metros, radianes). three.js es y-arriba,
// así que todo cuelga de un grupo girado −90° en x. Cada cuerpo se crea alineado con el mundo en la
// configuración cero; así el eje de cada articulación es el mismo vector en los dos cuerpos.
//
// La app nativa lo maneja con window.studio.* y recibe el estado por webkit.messageHandlers.studio.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { ColladaLoader } from "three/addons/loaders/ColladaLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { ConvexGeometry } from "three/addons/geometries/ConvexGeometry.js";
import RAPIER_MODULE from "./lib/rapier.es.js";
import { parseURDF } from "./model-urdf.js";
import { parseMJCF } from "./model-mjcf.js";
import { triangles, decompose } from "./decompose.js";

const RAPIER = RAPIER_MODULE;
const post = (msg) => {
  try { window.webkit.messageHandlers.studio.postMessage(msg); } catch { /* fuera de la app no hay a quién avisar */ }
};
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

// Grupos de colisión: el robot (1) choca con el resto (2); consigo mismo solo si se activa.
const G_ROBOT = 0x0001, G_WORLD = 0x0002;
const groups = (member, filter) => (member << 16) | filter;

// ---------- estado ----------
let renderer, scene, camera, controls, root, markers, ground, grid;
let world = null, eventQueue = null;
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

// ---------- utilidades de geometría ----------
const vec = (s, d = [0, 0, 0]) => (s ? s.trim().split(/\s+/).map(Number) : d);
const quatRPY = ([r, p, y]) => new THREE.Quaternion().setFromEuler(new THREE.Euler(r, p, y, "ZYX"));
const toR = (v) => ({ x: v.x, y: v.y, z: v.z });
const toRQ = (q) => ({ x: q.x, y: q.y, z: q.z, w: q.w });
const fromRQ = (q) => new THREE.Quaternion(q.x, q.y, q.z, q.w);

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
      if (!hit) throw new Error(`No encuentro la malla ${file}`);
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
      throw new Error(`Formato de malla no soportado: .${ext}`);
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
/** Arma cuerpos, colisiones y articulaciones a partir del modelo interno (URDF o MJCF). */
async function buildModel(im, base, profile) {
  const links = new Map(im.links.map((l) => [l.name, l]));
  const childOf = new Set(im.joints.map((j) => j.child));
  const byParent = new Map();
  for (const j of im.joints) { if (!byParent.has(j.parent)) byParent.set(j.parent, []); byParent.get(j.parent).push(j); }
  const rootLink = im.links.find((l) => !childOf.has(l.name))?.name;
  if (!rootLink) throw new Error("El modelo no tiene una pieza raíz.");
  const decomposeParts = profile?.collision?.maxParts ?? 8;

  // Pose de cada pieza en la configuración cero (de la raíz a las puntas).
  const pose = new Map([[rootLink, { p: new THREE.Vector3(), q: new THREE.Quaternion() }]]);
  const order = [rootLink];
  for (let i = 0; i < order.length; i++) {
    const parent = pose.get(order[i]);
    for (const j of byParent.get(order[i]) || []) {
      if (pose.has(j.child)) continue;
      pose.set(j.child, { p: new THREE.Vector3(...j.pos).applyQuaternion(parent.q).add(parent.p), q: parent.q.clone().multiply(arrQ(j.quat)) });
      order.push(j.child);
    }
  }

  const warnings = [...(im.warnings || [])];
  const floating = new Set(im.joints.filter((j) => j.type === "floating").map((j) => j.child));
  const out = { name: im.name, links: new Map(), joints: [], allJoints: [], rootLink, mass: 0, floating: floating.size > 0 };
  let decomposed = 0;
  for (const name of order) {
    const l = links.get(name), { p, q } = pose.get(name);
    // Cuerpo alineado con el mundo en la pose cero; las formas llevan la rotación de la pieza.
    const fixed = name === rootLink && (params.fixedBase || name === "world");
    const body = world.createRigidBody((fixed ? RAPIER.RigidBodyDesc.fixed() : RAPIER.RigidBodyDesc.dynamic())
      .setTranslation(p.x, p.y, p.z).setCanSleep(false));
    const group = new THREE.Group();
    group.position.copy(p);
    root.add(group);
    const linkFrame = new THREE.Matrix4().makeRotationFromQuaternion(q);  // marco de la pieza dentro del cuerpo

    // Visual
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
        const holder = new THREE.Group();
        holder.applyMatrix4(linkFrame);
        const off = new THREE.Group();
        off.position.set(...v.pos);
        off.quaternion.copy(arrQ(v.quat));
        off.add(obj);
        holder.add(off);
        group.add(holder);
      } catch (e) { warnings.push(`${name}: ${e.message}`); }
    }

    // Colisión: envolventes convexas; las mallas cóncavas se parten en varias (decompose.js).
    const shapes = l.collisions.length ? l.collisions : l.visuals;
    const colliders = [];
    for (const s of shapes) {
      try {
        const obj = await shapeObject(s, base);
        const off = new THREE.Group();
        off.position.set(...s.pos);
        off.quaternion.copy(arrQ(s.quat));
        off.add(obj);
        const { parts } = s.geometry.type === "mesh" ? decompose(triangles(off, linkFrame), decomposeParts) : decompose(triangles(off, linkFrame), 1);
        if (parts.length > 1) decomposed++;
        for (const pts of parts) {
          const cd = RAPIER.ColliderDesc.convexHull(pts);
          if (!cd) continue;
          cd.setFriction(params.friction).setRestitution(params.restitution)
            .setCollisionGroups(groups(G_ROBOT, params.selfCollision ? G_ROBOT | G_WORLD : G_WORLD))
            .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS);
          if (l.inertial?.mass > 0) cd.setDensity(0);
          const c = world.createCollider(cd, body);
          c.userData = { link: name };
          colliders.push(c);
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

    // Masa e inercia (en el marco del cuerpo). Las piezas virtuales llevan una masa mínima.
    if (l.inertial?.mass > 0) {
      const com = new THREE.Vector3(...l.inertial.pos).applyQuaternion(q);
      const frame = q.clone().multiply(arrQ(l.inertial.quat));
      const [ix, iy, iz] = l.inertial.inertia.map((v) => Math.max(v, 1e-7));
      body.setAdditionalMassProperties(l.inertial.mass, toR(com), { x: ix, y: iy, z: iz }, toRQ(frame), true);
    } else if (!colliders.length && !fixed) {
      body.setAdditionalMassProperties(1e-3, { x: 0, y: 0, z: 0 }, { x: 1e-7, y: 1e-7, z: 1e-7 }, { x: 0, y: 0, z: 0, w: 1 }, true);
      if (!l.virtual) warnings.push(`${name}: sin masa ni colisión; se le da 1 g`);
    }

    const com = new THREE.Mesh(new THREE.SphereGeometry(0.006, 12, 8), debugMaterials.com);
    const lc = body.localCom();
    com.position.set(lc.x, lc.y, lc.z);
    com.userData.layer = "com";
    com.visible = render.com;
    group.add(com);
    out.mass += l.inertial?.mass > 0 ? l.inertial.mass : colliders.reduce((m, c) => m + c.mass(), 0);
    out.links.set(name, { name, body, group, q0: q.clone(), p0: p.clone(), colliders, virtual: !!l.virtual });
  }
  if (decomposed) warnings.push(`${decomposed} piezas cóncavas se partieron en varias formas convexas para chocar mejor`);

  // Articulaciones
  for (const j of im.joints) {
    const parent = out.links.get(j.parent), child = out.links.get(j.child);
    if (!parent || !child) continue;
    const cp = pose.get(j.child);
    // Punto de giro en el mundo (pose cero) y su posición en cada cuerpo (alineados con el mundo).
    const anchor = new THREE.Vector3(...j.anchor).applyQuaternion(cp.q).add(cp.p);
    const a1 = anchor.clone().sub(parent.p0), a2 = anchor.clone().sub(child.p0);
    const axis = new THREE.Vector3(...j.axis).normalize().applyQuaternion(cp.q);
    const info = { name: j.name, type: j.type, parent: j.parent, child: j.child, a1, a2, axis };
    out.allJoints.push(info);
    if (j.type === "floating") continue;   // base flotante: el cuerpo queda libre

    let data;
    if (j.type === "revolute" || j.type === "continuous") data = RAPIER.JointData.revolute(toR(a1), toR(a2), toR(axis));
    else if (j.type === "prismatic") data = RAPIER.JointData.prismatic(toR(a1), toR(a2), toR(axis));
    else if (j.type === "spherical") data = RAPIER.JointData.spherical(toR(a1), toR(a2));
    else data = RAPIER.JointData.fixed(toR(a1), { x: 0, y: 0, z: 0, w: 1 }, toR(a2), { x: 0, y: 0, z: 0, w: 1 });
    const limited = (j.type === "revolute" || j.type === "prismatic") && j.lower != null && j.upper != null && j.upper > j.lower;
    if (limited) { data.limitsEnabled = true; data.limits = [j.lower, j.upper]; }
    const rj = world.createImpulseJoint(data, parent.body, child.body, true);
    rj.setContactsEnabled(false);  // las piezas vecinas no chocan entre sí (como MuJoCo)
    if (j.type === "fixed" || j.type === "spherical") continue;

    const arrow = new THREE.ArrowHelper(axis.clone(), a2.clone(), 0.05, 0xff4fa3, 0.012, 0.008);
    arrow.userData.layer = "joints";
    arrow.visible = render.joints;
    child.group.add(arrow);

    const saved = profile?.actuators?.[j.name] || {};
    const act = j.actuator || {};
    const fmax = saved.fmax ?? act.fmax ?? (j.effort > 0 ? j.effort : 10);
    const kp = saved.kp ?? act.kp ?? fmax * 10;            // fuerza máxima con ~0.1 rad (o m) de error
    const kd = saved.kd ?? act.kd ?? kp * 0.05;
    rj.configureMotorModel(RAPIER.MotorModel.ForceBased);
    const driven = j.actuated || !!j.mimic;
    // Pasiva: sin motor de posición, solo su amortiguación.
    if (!driven && j.damping > 0) rj.configureMotorVelocity(0, j.damping);
    out.joints.push({
      ...info, lower: limited ? j.lower : null, upper: limited ? j.upper : null,
      effort: j.effort, velocity: j.velocity, rj, kp, kd, fmax,
      actuated: !!j.actuated, mimic: j.mimic, driven,
      target: limited ? clamp(0, j.lower, j.upper) : 0, q: 0, qd: 0, force: 0, turns: 0, lastRaw: 0,
    });
  }
  // De la base a la punta (el orden del árbol), no el del archivo.
  const rank = new Map(order.map((n, i) => [n, i]));
  out.joints.sort((a, b) => rank.get(a.child) - rank.get(b.child));
  const byName = new Map(out.joints.map((j) => [j.name, j]));
  for (const j of out.joints) if (j.mimic) j.master = byName.get(j.mimic.joint) || null;
  return { ...out, warnings };
}

// ---------- coordenadas de las articulaciones (sensores) ----------
const _qa = new THREE.Quaternion(), _qb = new THREE.Quaternion(), _v = new THREE.Vector3(), _w = new THREE.Vector3();
function measure(j) {
  const pb = model.links.get(j.parent).body, cb = model.links.get(j.child).body;
  _qa.copy(fromRQ(pb.rotation())).invert();
  if (j.type === "prismatic") {
    const pp = pb.translation(), cp = cb.translation();
    _v.copy(j.a2).applyQuaternion(fromRQ(cb.rotation())).add(_w.set(cp.x, cp.y, cp.z));
    _w.copy(j.a1).applyQuaternion(fromRQ(pb.rotation())).add(new THREE.Vector3(pp.x, pp.y, pp.z));
    return _v.sub(_w).applyQuaternion(_qa).dot(j.axis);
  }
  _qb.copy(_qa).multiply(fromRQ(cb.rotation()));
  let raw = 2 * Math.atan2(_v.set(_qb.x, _qb.y, _qb.z).dot(j.axis), _qb.w);
  raw = Math.atan2(Math.sin(raw), Math.cos(raw));
  if (j.type === "continuous") {  // da vueltas completas: se cuentan
    if (raw - j.lastRaw > Math.PI) j.turns--;
    else if (j.lastRaw - raw > Math.PI) j.turns++;
    j.lastRaw = raw;
    return raw + j.turns * 2 * Math.PI;
  }
  return raw;
}

/** Actuador de posición con fuerza máxima: el objetivo efectivo nunca pide más que fmax. */
function gauss() { let u = 0, v = 0; while (!u) u = Math.random(); while (!v) v = Math.random(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); }

function drive(j) {
  if (!j.driven) return;
  // Acoplada: sigue a su articulación maestra (como <mimic> en URDF o <equality joint> en MJCF).
  if (j.mimic && j.master) j.target = j.mimic.multiplier * j.master.target + j.mimic.offset;
  let target = j.lower != null ? clamp(j.target, j.lower, j.upper) : j.target;
  if (params.noiseScale > 0) {
    const span = j.lower != null ? j.upper - j.lower : (j.type === "prismatic" ? 0.2 : Math.PI);
    const rate = Math.max(params.noiseRate, params.timestep);
    const a = Math.exp(-params.timestep / rate);
    j.noise = a * (j.noise || 0) + Math.sqrt(1 - a * a) * params.noiseScale * gauss();
    target += j.noise * span / 2;
    if (j.lower != null) target = clamp(target, j.lower, j.upper);
  } else j.noise = 0;
  const reach = j.fmax / Math.max(j.kp, 1e-6);
  const eff = j.q + clamp(target - j.q, -reach, reach);
  j.rj.configureMotorPosition(eff, j.kp, j.kd);
  j.force = clamp(j.kp * (eff - j.q) - j.kd * j.qd, -j.fmax, j.fmax);  // estimada
}

// ---------- escena ----------
function makeWorld() {
  if (world) world.free();
  world = new RAPIER.World({ x: 0, y: 0, z: -params.gravity });
  world.timestep = params.timestep;
  world.numSolverIterations = params.iterations;
  eventQueue = new RAPIER.EventQueue(true);
  const g = world.createCollider(RAPIER.ColliderDesc.cuboid(5, 5, 0.05).setTranslation(0, 0, -0.05)
    .setFriction(params.friction).setCollisionGroups(groups(G_WORLD, G_ROBOT | G_WORLD)));
  g.userData = { ground: true };
}

function clearScene() {
  for (const l of model?.links.values() || []) root.remove(l.group);
  for (const o of objects) root.remove(o.mesh);
  for (const c of cameras) c.cam.parent?.remove(c.cam);
  model = null; objects = []; cameras = []; activeCamera = null;
}

function addObject(spec) {
  const o = { id: spec.id ?? nextObjectId++, shape: spec.shape || "box", size: spec.size || [0.05, 0.05, 0.05],
    mass: spec.mass ?? 0.05, color: spec.color || "#c8a27a", pos: spec.pos || [0.2, 0, 0.1], yaw: spec.yaw || 0,
    fixed: !!spec.fixed, name: spec.name || "" };
  nextObjectId = Math.max(nextObjectId, o.id + 1);
  const q = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), o.yaw * Math.PI / 180);
  const body = world.createRigidBody((o.fixed ? RAPIER.RigidBodyDesc.fixed() : RAPIER.RigidBodyDesc.dynamic())
    .setTranslation(...o.pos).setRotation(toRQ(q)));
  let cd, geo;
  if (o.shape === "sphere") { cd = RAPIER.ColliderDesc.ball(o.size[0]); geo = new THREE.SphereGeometry(o.size[0], 32, 16); }
  else if (o.shape === "cylinder") {
    cd = RAPIER.ColliderDesc.cylinder(o.size[1] / 2, o.size[0]).setRotation(toRQ(new THREE.Quaternion().setFromEuler(new THREE.Euler(Math.PI / 2, 0, 0))));
    geo = new THREE.CylinderGeometry(o.size[0], o.size[0], o.size[1], 32).rotateX(Math.PI / 2);
  } else { cd = RAPIER.ColliderDesc.cuboid(o.size[0] / 2, o.size[1] / 2, o.size[2] / 2); geo = new THREE.BoxGeometry(...o.size); }
  cd.setMass(Math.max(o.mass, 1e-4)).setFriction(params.friction).setRestitution(params.restitution)
    .setCollisionGroups(groups(G_WORLD, G_ROBOT | G_WORLD)).setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS);
  o.body = body;
  o.collider = world.createCollider(cd, body);
  o.collider.userData = { object: o.id };
  o.mesh = new THREE.Mesh(geo, new THREE.MeshStandardMaterial({ color: o.color, roughness: 0.7 }));
  o.mesh.castShadow = o.mesh.receiveShadow = true;
  o.mesh.userData.obj = o;
  root.add(o.mesh);
  objects.push(o);
  return o.id;
}

function removeObject(id) {
  const o = objects.find((x) => x.id === id);
  if (!o) return;
  world.removeRigidBody(o.body);
  root.remove(o.mesh);
  objects = objects.filter((x) => x !== o);
}

function addCamera(spec) {
  const link = model?.links.get(spec.link);
  if (!link) return;  // la cámara va en una pieza que este modelo no tiene
  const cam = new THREE.PerspectiveCamera(spec.fovy || 60, (spec.width || 640) / (spec.height || 480), 0.005, 20);
  // Pose dentro del link (convención de MuJoCo: mira hacia −z, y hacia arriba). quat [x,y,z,w] o rpy.
  const q = spec.quat ? new THREE.Quaternion(...spec.quat) : quatRPY(spec.rpy || [0, 0, 0]);
  const holder = new THREE.Group();
  holder.quaternion.copy(link.q0);
  cam.position.set(...(spec.pos || [0, 0, 0]));
  cam.quaternion.copy(q);
  holder.add(cam);
  link.group.add(holder);
  cameras.push({ ...spec, cam });
}

// ---------- paso de simulación ----------
function physicsStep() {
  const t0 = performance.now();
  for (const j of model?.joints || []) drive(j);
  world.step(eventQueue);
  stepMs = 0.98 * stepMs + 0.02 * (performance.now() - t0);
  simTime += params.timestep;
  for (const j of model?.joints || []) {
    const q = measure(j);
    j.qd = (q - j.q) / params.timestep;
    j.q = q;
  }
}

function sync() {
  for (const l of model?.links.values() || []) {
    const t = l.body.translation(), r = l.body.rotation();
    l.group.position.set(t.x, t.y, t.z);
    l.group.quaternion.set(r.x, r.y, r.z, r.w);
  }
  for (const o of objects) {
    const t = o.body.translation(), r = o.body.rotation();
    o.mesh.position.set(t.x, t.y, t.z);
    o.mesh.quaternion.set(r.x, r.y, r.z, r.w);
  }
}

const MAX_MARKERS = 256;
function updateContacts() {
  let n = 0, maxForce = 0;
  const linkForce = {}, color = new THREE.Color(), m4 = new THREE.Matrix4();
  const seen = new Set();
  const visit = (collider) => {
    world.contactPairsWith(collider, (other) => {
      const key = collider.handle < other.handle ? `${collider.handle}-${other.handle}` : `${other.handle}-${collider.handle}`;
      if (seen.has(key)) return;
      seen.add(key);
      world.contactPair(collider, other, (m) => {
        if (m.numSolverContacts() === 0) return;
        let impulse = 0;
        for (let i = 0; i < m.numContacts(); i++) impulse += m.contactImpulse(i);
        const force = impulse / params.timestep;
        maxForce = Math.max(maxForce, force);
        for (const c of [collider, other]) if (c.userData?.link) linkForce[c.userData.link] = (linkForce[c.userData.link] || 0) + force;
        for (let i = 0; i < m.numSolverContacts() && n < MAX_MARKERS; i++, n++) {
          const p = m.solverContactPoint(i);
          markers.setMatrixAt(n, m4.makeTranslation(p.x, p.y, p.z));
          markers.setColorAt(n, color.setHSL(0.33 * (1 - clamp(force / 5, 0, 1)), 0.85, 0.5));
        }
      });
    });
  };
  for (const l of model?.links.values() || []) l.colliders.forEach(visit);
  for (const o of objects) visit(o.collider);
  markers.count = n;
  markers.instanceMatrix.needsUpdate = true;
  if (markers.instanceColor) markers.instanceColor.needsUpdate = true;
  readout = { contacts: n, maxForce, links: linkForce };
}

function postState(now) {
  if (now - lastPost < 100) return;
  lastPost = now;
  post({
    type: "state", t: simTime, rtf, paused, mode, stepMs,
    joints: (model?.joints || []).map((j) => ({ name: j.name, q: j.q, qd: j.qd, target: j.target, force: j.force })),
    contacts: readout.contacts, maxForce: readout.maxForce,
    links: Object.entries(readout.links).map(([name, force]) => ({ name, force })),
    objects: objects.map((o) => { const t = o.body.translation(); return { id: o.id, pos: [t.x, t.y, t.z] }; }),
  });
}

function frame(now) {
  const dtWall = Math.min(0.1, (now - (wallLast || now)) / 1000);
  wallLast = now;
  if (world && model && !paused) {
    accum += dtWall * speed;
    const t0 = simTime, start = performance.now();
    while (accum >= params.timestep && performance.now() - start < 25) { physicsStep(); accum -= params.timestep; }
    if (accum > params.timestep * 4) accum = 0;  // no alcanza: se desacelera en vez de acumular
    rtf = dtWall > 0 ? 0.9 * rtf + 0.1 * ((simTime - t0) / dtWall) : rtf;
  } else rtf = 0;
  if (world) { sync(); if (render.contacts) updateContacts(); else { markers.count = 0; readout = { contacts: 0, maxForce: 0, links: {} }; } }
  pullDragged();
  controls.update();
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

// ---------- empujar objetos con Shift + arrastrar ----------
const raycaster = new THREE.Raycaster(), pointer = new THREE.Vector2();
let drag = null;
function rayFrom(e) {
  const r = renderer.domElement.getBoundingClientRect();
  pointer.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  raycaster.setFromCamera(pointer, camera);
}
function onPointerDown(e) {
  if (!e.shiftKey || !world) return;
  rayFrom(e);
  const hit = raycaster.intersectObjects(objects.map((o) => o.mesh))[0];
  if (!hit) return;
  e.stopPropagation();
  controls.enabled = false;
  drag = { obj: hit.object.userData.obj, plane: new THREE.Plane(new THREE.Vector3(0, 1, 0), -hit.point.y), to: hit.point.clone() };
  window.addEventListener("pointermove", onPointerMove);
  window.addEventListener("pointerup", () => { drag = null; controls.enabled = true; window.removeEventListener("pointermove", onPointerMove); }, { once: true });
}
function onPointerMove(e) { if (drag) { rayFrom(e); raycaster.ray.intersectPlane(drag.plane, drag.to); } }
function pullDragged() {
  if (!drag || paused) return;
  const t = drag.obj.body.translation(), local = root.worldToLocal(drag.to.clone());
  const k = drag.obj.body.mass() * 60;
  drag.obj.body.resetForces(true);
  drag.obj.body.addForce({ x: (local.x - t.x) * k, y: (local.y - t.y) * k, z: 0 }, true);
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
  Object.assign(sun.shadow.camera, { left: -1, right: 1, top: 1, bottom: -1, near: 0.1, far: 8 });
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
  new ResizeObserver(resize).observe(canvas);
  resize();
  renderer.setAnimationLoop(frame);
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
      post({ type: "loading", text: "Leyendo el modelo…" });
      const res = await fetch(url);
      if (!res.ok) throw new Error(`No se pudo leer ${url}`);
      const text = await res.text();
      const urdf = /<mujoco[\s>]/.test(text) ? await parseMJCF(text, url) : parseURDF(text);
      if (token !== currentLoad) return;
      clearScene();
      Object.assign(params, profile.physics || {});
      makeWorld();
      simTime = 0;
      post({ type: "loading", text: `Armando ${urdf.links.filter((l) => !l.virtual).length} piezas…` });
      const built = await buildModel(urdf, url.slice(0, url.lastIndexOf("/")), profile);
      if (token !== currentLoad) return;
      model = built;
      for (const c of [...(urdf.cameras || []), ...(profile.cameras || [])]) addCamera(c);
      for (const o of profile.scene?.objects || []) addObject(o);
      homeTargets = { ...(urdf.home || {}), ...(profile.home || {}) };
      this.reset(true);
      sync();
      applyRender();
      frameModel();
      post({
        type: "model", name: model.name, root: model.rootLink,
        links: [...model.links.values()].filter((l) => !l.virtual).map((l) => l.name),
        joints: model.joints.map((j) => ({ name: j.name, type: j.type, parent: j.parent, child: j.child,
          lower: j.lower, upper: j.upper, effort: j.effort, velocity: j.velocity, kp: j.kp, kd: j.kd, fmax: j.fmax,
          actuated: j.actuated, mimic: j.mimic?.joint ?? null })),
        floating: model.floating,
        fixedJoints: urdf.joints.filter((j) => j.type === "fixed").length,
        mass: model.mass,
        cameras: cameras.map((c) => c.name),
        objects: objects.map(({ id, shape, size, mass, color, pos, yaw, fixed, name }) => ({ id, shape, size, mass, color, pos, yaw, fixed, name })),
        physics: { ...params },
        warnings: built.warnings,
      });
    } catch (e) {
      post({ type: "error", text: e.message });
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
  },
  setPhysics(p) {
    Object.assign(params, p);
    if (!world) return;
    world.gravity = { x: 0, y: 0, z: -params.gravity };
    world.timestep = params.timestep;
    world.numSolverIterations = params.iterations;
    world.forEachCollider((c) => {
      c.setFriction(params.friction);
      c.setRestitution(params.restitution);
      if (c.userData?.link) c.setCollisionGroups(groups(G_ROBOT, params.selfCollision ? G_ROBOT | G_WORLD : G_WORLD));
    });
  },
  /** Coloca el robot de golpe en sus objetivos (o en la pose de reposo), quieto. Cinemática directa desde la raíz. */
  reset(zeroTargets = true) {
    if (!model) return;
    const value = new Map();
    for (const j of model.joints) {
      if (zeroTargets) j.target = homeTargets[j.name] ?? (j.lower != null ? clamp(0, j.lower, j.upper) : 0);
    }
    for (const j of model.joints) {
      if (j.mimic && j.master) j.target = j.mimic.multiplier * j.master.target + j.mimic.offset;
      value.set(j.name, j.lower != null ? clamp(j.target, j.lower, j.upper) : j.target);
    }
    const byParent = new Map();
    for (const j of model.allJoints) { if (!byParent.has(j.parent)) byParent.set(j.parent, []); byParent.get(j.parent).push(j); }
    const rootL = model.links.get(model.rootLink);
    const pose = new Map([[model.rootLink, { p: rootL.p0.clone(), q: new THREE.Quaternion() }]]);
    const queue = [model.rootLink];
    while (queue.length) {
      const name = queue.shift(), parent = pose.get(name);
      for (const j of byParent.get(name) || []) {
        if (pose.has(j.child)) continue;
        if (j.type === "floating") {   // base flotante: vuelve a su pose inicial
          pose.set(j.child, { p: model.links.get(j.child).p0.clone(), q: new THREE.Quaternion() });
        } else {
          const v = value.get(j.name) ?? 0;
          const R = (j.type === "revolute" || j.type === "continuous") ? new THREE.Quaternion().setFromAxisAngle(j.axis, v) : new THREE.Quaternion();
          const local = j.a1.clone().sub(j.a2.clone().applyQuaternion(R));
          if (j.type === "prismatic") local.add(j.axis.clone().multiplyScalar(v));
          pose.set(j.child, { p: local.applyQuaternion(parent.q).add(parent.p), q: parent.q.clone().multiply(R) });
        }
        queue.push(j.child);
      }
    }
    for (const [name, { p, q }] of pose) {
      const b = model.links.get(name).body;
      b.setTranslation(toR(p), true);
      b.setRotation(toRQ(q), true);
      b.setLinvel({ x: 0, y: 0, z: 0 }, true);
      b.setAngvel({ x: 0, y: 0, z: 0 }, true);
    }
    for (const j of model.joints) { j.turns = 0; j.lastRaw = 0; j.q = measure(j); j.qd = 0; }
    sync();
  },
  /** Imagen JPEG (data URL) de la vista principal o de una cámara montada, para que la IA «mire». */
  capture(cameraName = null, width = 768, format = "jpeg") {
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
    return format === "png" ? canvas.toDataURL("image/png") : canvas.toDataURL("image/jpeg", 0.8);
  },
  resetObjects(list) {
    for (const o of [...objects]) removeObject(o.id);
    for (const o of list || []) addObject(o);
  },
  addObject(spec) { return addObject(spec); },
  removeObject(id) { removeObject(id); },
  addCamera(spec) { addCamera(spec); },
  removeCamera(name) {
    const c = cameras.find((x) => x.name === name);
    c?.cam.parent?.parent?.remove(c.cam.parent);
    cameras = cameras.filter((x) => x !== c);
    if (activeCamera === name) activeCamera = null;
  },
  showCamera(name) { activeCamera = name || null; },
  pause(on) { paused = on; },
  step(n = 1) { if (!world || !model) return; for (let i = 0; i < n; i++) physicsStep(); sync(); },
  setSpeed(x) { speed = x; },
  setMode(m) { mode = m; },
  view(name) { frameModel(name); },
  setRender(opts) { Object.assign(render, opts); applyRender(); },
  /** Estado completo (articulaciones y objetos) para un keyframe o para copiarlo. */
  /** Dónde está cada pieza (metros, marco de la base del robot): cinemática directa para la IA. */
  linkPositions() {
    if (!model) return {};
    const base = model.links.get(model.rootLink)?.body.translation() || { x: 0, y: 0, z: 0 };
    return Object.fromEntries([...model.links].map(([name, l]) => {
      const t = l.body.translation();
      return [name, [t.x - base.x, t.y - base.y, t.z - base.z]];
    }));
  },
  getKeyframe() {
    return {
      time: simTime,
      q: Object.fromEntries((model?.joints || []).map((j) => [j.name, j.q])),
      objects: objects.map((o) => { const t = o.body.translation(), r = o.body.rotation(); return { id: o.id, pos: [t.x, t.y, t.z], quat: [r.x, r.y, r.z, r.w] }; }),
    };
  },
  setKeyframe(k) {
    if (!model || !k) return;
    for (const j of model.joints) if (k.q?.[j.name] != null) j.target = k.q[j.name];
    this.reset(false);
    for (const s of k.objects || []) {
      const o = objects.find((x) => x.id === s.id);
      if (!o) continue;
      o.body.setTranslation({ x: s.pos[0], y: s.pos[1], z: s.pos[2] }, true);
      o.body.setRotation({ x: s.quat[0], y: s.quat[1], z: s.quat[2], w: s.quat[3] }, true);
      o.body.setLinvel({ x: 0, y: 0, z: 0 }, true);
      o.body.setAngvel({ x: 0, y: 0, z: 0 }, true);
    }
    sync();
  },
  setInsets({ right = 0 }) { if (right !== insetRight) { insetRight = right; resize(); } },
  /** Pose actual, para guardar un keyframe. */
  snapshot() { return Object.fromEntries((model?.joints || []).map((j) => [j.name, j.q])); },
};

try {
  await RAPIER.init();
  setup();
  post({ type: "ready" });
} catch (e) {
  post({ type: "error", text: `No se pudo iniciar el motor: ${e.message}` });
}
