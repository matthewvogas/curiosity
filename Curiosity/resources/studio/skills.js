// Ejecutor de habilidades: la IA dice «qué» (agarrá lo que está en este píxel, dejalo en este otro) y esto hace
// el «cómo» en tiempo real, como lo haría con el robot real. No lee dónde están los objetos: solo usa
//  · la cámara: un píxel → un rayo → dónde corta el plano de la mesa (a la altura que diga la IA),
//  · la cinemática del brazo (cinemática inversa numérica sobre MuJoCo, sirve para cualquier brazo),
//  · y lo que el robot siente: si la pinza se cerró del todo o quedó trabada en algo.
//
// Unidades: metros y radianes, mundo de MuJoCo (z hacia arriba, la mesa en z = 0).

import * as THREE from "three";

const GRIPPER_NAME = /grip|finger|jaw|claw/i;
const TCP_NAME = /tcp|gripper_frame|end_?effector|ee_link|tool/i;
const DOWN = [0, 0, -1];
// Cuánto pesan, frente a la posición (m por unidad), apuntar hacia abajo y cerrar en la dirección pedida. Se
// prueba de más a menos: un brazo de pocas articulaciones no siempre puede las dos cosas, y llegar al punto
// importa más que la inclinación o el giro.
const WEIGHTS = [[0.08, 0.06], [0.03, 0.06], [0.03, 0.02], [0.01, 0.01], [0, 0]];
const JOINT_SPEED = 2.0;      // rad/s como máximo a lo largo de un tramo
const CLEARANCE = 0.06;       // altura de aproximación sobre el objetivo

const sub = (a, b) => a.map((v, i) => v - b[i]);
const norm = (a) => Math.hypot(...a);
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const smooth = (s) => s * s * (3 - 2 * s);

/** Resuelve A x = b (A cuadrada chica) por eliminación gaussiana. */
function solve(A, b) {
  const n = b.length, M = A.map((row, i) => [...row, b[i]]);
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    [M[c], M[p]] = [M[p], M[c]];
    for (let r = c + 1; r < n; r++) {
      const f = M[r][c] / M[c][c];
      for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k];
    }
  }
  const x = new Array(n).fill(0);
  for (let r = n - 1; r >= 0; r--) {
    let s = M[r][n];
    for (let k = r + 1; k < n; k++) s -= M[r][k] * x[k];
    x[r] = s / M[r][r];
  }
  return x;
}

/**
 * ctx.get() → { mj, mjm, mjd, model, root, cameras }: el estado vivo del motor (cambia al recompilar).
 * ctx.config: el «effector» del perfil, opcional: { link, gripper, open, closed }.
 */
export function createSkills(ctx) {
  let scratch = null, scratchModel = null;
  let task = null;   // la habilidad en curso: { steps, i, t, resolve, result }

  // ---------- el brazo ----------
  function ensureScratch() {
    const { mj, mjm } = ctx.get();
    if (scratchModel !== mjm) { scratch?.delete(); scratch = new mj.MjData(mjm); scratchModel = mjm; effCache = null; }
  }
  let effCache = null;

  /** Cómo es el brazo: la cadena hasta la punta, la pinza, sus dedos y el centro del agarre. Se calcula una vez. */
  function effector() {
    const { model, mjm } = ctx.get();
    ensureScratch();
    if (effCache && effCache.mjm === mjm && effCache.model === model) return effCache.eff;
    const cfg = ctx.config() || {};
    const parentJoint = new Map(model.joints.map((j) => [j.child, j]));   // solo las que se mueven
    const parentOf = model.parentOf ?? new Map(model.joints.map((j) => [j.child, j.parent]));
    const gripper = model.joints.find((j) => j.name === cfg.gripper)
      ?? model.joints.find((j) => j.actuated && j.qadr >= 0 && j.lower != null && GRIPPER_NAME.test(j.name));
    const links = [...model.links.values()].filter((l) => l.body >= 0);
    let tcp = model.links.get(cfg.link)?.name ?? links.find((l) => TCP_NAME.test(l.name))?.name ?? gripper?.parent;
    if (!tcp) {
      const depth = (n) => (parentOf.has(n) ? 1 + depth(parentOf.get(n)) : 0);
      tcp = links.reduce((a, b) => (depth(b.name) > depth(a.name) ? b : a)).name;
    }
    // La «mano»: de ella a la punta es hacia donde apunta la herramienta (si nadie dice otra cosa).
    const hand = gripper && gripper.parent !== tcp ? gripper.parent : parentOf.get(tcp);
    const arm = [];
    for (let l = tcp; parentOf.has(l); l = parentOf.get(l)) {
      const j = parentJoint.get(l);
      if (j && j.actuated && j.qadr >= 0 && j !== gripper) arm.unshift(j);
    }
    const eff = { tcpBody: model.links.get(tcp).body, handBody: model.links.get(hand)?.body ?? -1, arm, tcp,
      grip: null, offset: cfg.offset ?? [0, 0, 0], axisLocal: cfg.axis ?? null, closeLocal: cfg.close_axis ?? null, maxWidth: null };
    if (gripper) {
      const far = Math.abs(gripper.upper) >= Math.abs(gripper.lower) ? gripper.upper : gripper.lower;
      const near = far === gripper.upper ? gripper.lower : gripper.upper;
      const followers = model.joints.filter((j) => j.qadr >= 0 && (j.mimic?.joint ?? j.mimic) === gripper.name);
      eff.grip = { joint: gripper, followers, open: cfg.open ?? far, closed: cfg.closed ?? near };
      measureGripper(eff, !cfg.offset, !cfg.axis, !cfg.close_axis);
    }
    effCache = { mjm, model, eff };
    return eff;
  }

  /** Pone el brazo (y la pinza, con sus dedos acoplados) en `q` en la copia de trabajo y calcula las poses. */
  function pose(eff, q, gripQ = null) {
    const { mj, mjm, mjd } = ctx.get();
    ensureScratch();
    scratch.qpos.set(mjd.qpos);
    eff.arm.forEach((j, i) => { scratch.qpos[j.qadr] = q[i]; });
    if (gripQ != null && eff.grip) {
      scratch.qpos[eff.grip.joint.qadr] = gripQ;
      for (const f of eff.grip.followers) scratch.qpos[f.qadr] = (f.mimic.multiplier ?? 1) * gripQ + (f.mimic.offset ?? 0);
    }
    mj.mj_kinematics(mjm, scratch);
    return scratch;
  }

  const vecOf = (arr, k) => [arr[k * 3], arr[k * 3 + 1], arr[k * 3 + 2]];
  const rotate = (m, b, v) => [0, 1, 2].map((r) => m[b * 9 + r * 3] * v[0] + m[b * 9 + r * 3 + 1] * v[1] + m[b * 9 + r * 3 + 2] * v[2]);
  const unrotate = (m, b, v) => [0, 1, 2].map((c) => m[b * 9 + c] * v[0] + m[b * 9 + 3 + c] * v[1] + m[b * 9 + 6 + c] * v[2]);
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const unit = (v) => { const n = norm(v) || 1; return v.map((x) => x / n); };

  /**
   * Mide la pinza con su geometría real (sirve para cualquier pinza): dónde queda el centro del agarre (entre los
   * dedos, un poco antes de las puntas), hacia dónde apunta, en qué dirección cierran los dedos y cuánto abre.
   * Todo en el marco de la punta, para que valga en cualquier postura.
   */
  function measureGripper(eff, wantOffset, wantAxis, wantClose) {
    const { model, mjm } = ctx.get();
    const g = eff.grip;
    const fingerBodies = [g.joint.child, ...g.followers.map((f) => f.child)].map((n) => model.links.get(n)?.body).filter((b) => b >= 0);
    if (!fingerBodies.length) return;
    const geomsOf = (b) => { const out = []; for (let k = 0; k < mjm.ngeom; k++) if (mjm.geom_bodyid[k] === b) out.push(k); return out; };
    const q = eff.arm.map((j) => ctx.get().mjd.qpos[j.qadr]);
    const at = (gq) => {
      const d = pose(eff, q, gq);
      return { tcp: vecOf(d.xpos, eff.tcpBody), hand: eff.handBody >= 0 ? vecOf(d.xpos, eff.handBody) : null,
        coms: fingerBodies.map((b) => vecOf(d.xipos, b)), xmat: Float64Array.from(d.xmat), gxpos: Float64Array.from(d.geom_xpos), gxmat: Float64Array.from(d.geom_xmat) };
    };
    const open = at(g.open), closed = at(g.closed);
    const mid = (pts) => [0, 1, 2].map((i) => pts.reduce((s, p) => s + p[i], 0) / pts.length);
    const toLocal = (v) => unrotate(closed.xmat, eff.tcpBody, v);
    const handBody = model.links.get(g.joint.parent)?.body ?? eff.handBody;
    if (fingerBodies.length === 1) return measureOneJaw(eff, { open, closed, toLocal, handBody, geomsOf, jawBody: fingerBodies[0], wantOffset, wantAxis, wantClose });
    // Hacia dónde apunta: de la mano (o la punta) al medio de los dedos.
    const fingersMid = mid(closed.coms);
    let approach = eff.axisLocal ? rotate(closed.xmat, eff.tcpBody, eff.axisLocal) : sub(fingersMid, closed.hand ?? closed.tcp);
    if (norm(approach) < 1e-4) approach = DOWN;
    approach = unit(approach);
    if (wantAxis) eff.axisLocal = unit(toLocal(approach));
    // Hasta dónde llegan los dedos a lo largo de ese eje (las esquinas de sus geometrías).
    let tip = -Infinity;
    for (const b of fingerBodies) for (const k of geomsOf(b)) {
      const c = [mjm.geom_aabb[k * 6], mjm.geom_aabb[k * 6 + 1], mjm.geom_aabb[k * 6 + 2]];
      const h = [mjm.geom_aabb[k * 6 + 3], mjm.geom_aabb[k * 6 + 4], mjm.geom_aabb[k * 6 + 5]];
      for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const sz of [-1, 1]) {
        const local = [c[0] + sx * h[0], c[1] + sy * h[1], c[2] + sz * h[2]];
        const world = rotate(closed.gxmat, k, local).map((v, i) => v + closed.gxpos[k * 3 + i]);
        tip = Math.max(tip, dot(sub(world, fingersMid), approach));
      }
    }
    if (!Number.isFinite(tip)) tip = 0;
    // El centro del agarre: entre los dedos, ~1,2 cm antes de las puntas (ahí queda el medio del objeto).
    const graspWorld = fingersMid.map((v, i) => v + approach[i] * Math.max(0, tip - 0.012));
    if (wantOffset) eff.offset = toLocal(sub(graspWorld, closed.tcp));
    // Hacia dónde cierran: lo que se mueve un dedo al cerrar, sin la parte a lo largo del eje.
    const move = sub(closed.coms[0], open.coms[0]);
    const across = sub(move, approach.map((v) => v * dot(move, approach)));
    if (wantClose && norm(across) > 1e-4) eff.closeLocal = unit(toLocal(across));
    // Cuánto abre: con dos dedos, cuánto se separan; con uno, cuánto se mueve hacia el otro lado.
    const spread = (st) => (st.coms.length > 1 ? Math.abs(dot(sub(st.coms[0], st.coms[1]), unit(across))) : 0);
    eff.maxWidth = fingerBodies.length > 1 ? Math.max(0, spread(open) - spread(closed)) + 0.005 : norm(across);
  }

  /**
   * Una pinza con un dedo fijo (parte de la mano) y uno que se mueve hacia él: el objeto queda entre los dos,
   * así que el centro del agarre está corrido desde el dedo fijo hacia el móvil la mitad del ancho del objeto
   * (ver `grasp` en fk). El dedo fijo: el link de la herramienta si el robot lo declara (tcp, gripper_frame…),
   * si no, lo más saliente de la mano a lo largo del eje.
   */
  function measureOneJaw(eff, { open, closed, toLocal, handBody, geomsOf, jawBody, wantOffset, wantAxis, wantClose }) {
    const { mjm } = ctx.get();
    const handOrigin = (() => { const d = pose(eff, eff.arm.map((j) => ctx.get().mjd.qpos[j.qadr]), eff.grip.closed); return vecOf(d.xpos, handBody); })();
    const named = eff.tcp !== eff.grip.joint.parent && TCP_NAME.test(eff.tcp);
    let fixedTip;
    if (named) {
      fixedTip = closed.tcp;
    } else {
      // Lo más alejado de la mano en sus geometrías, en la dirección del dedo móvil.
      const guess = unit(sub(closed.coms[0], handOrigin));
      let best = -Infinity;
      for (const k of geomsOf(handBody)) {
        const c = [mjm.geom_aabb[k * 6], mjm.geom_aabb[k * 6 + 1], mjm.geom_aabb[k * 6 + 2]];
        const h = [mjm.geom_aabb[k * 6 + 3], mjm.geom_aabb[k * 6 + 4], mjm.geom_aabb[k * 6 + 5]];
        for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const sz of [-1, 1]) {
          const local = [c[0] + sx * h[0], c[1] + sy * h[1], c[2] + sz * h[2]];
          const world = rotate(closed.gxmat, k, local).map((v, i) => v + closed.gxpos[k * 3 + i]);
          const t = dot(sub(world, handOrigin), guess);
          if (t > best) { best = t; fixedTip = world; }
        }
      }
      fixedTip ??= closed.coms[0];
    }
    const approach = eff.axisLocal ? rotate(closed.xmat, eff.tcpBody, eff.axisLocal) : unit(sub(fixedTip, handOrigin));
    if (wantAxis) eff.axisLocal = unit(toLocal(approach));
    // 1,2 cm antes de la punta del dedo fijo, sobre el eje.
    if (wantOffset) eff.offset = toLocal(sub(fixedTip.map((v, i) => v - approach[i] * 0.012), closed.tcp));
    const move = sub(closed.coms[0], open.coms[0]);
    const across = sub(move, approach.map((v) => v * dot(move, approach)));
    if (wantClose && norm(across) > 1e-4) eff.closeLocal = unit(toLocal(across));
    eff.oneJaw = wantOffset;   // el corrimiento por el ancho solo si el centro lo medimos nosotros
    // Cuánto abre la punta del dedo móvil: si gira, lo que se mueve su centro de masa escalado por cuánto más
    // lejos del eje está la punta (lo más alejado de sus geometrías); si se desliza, lo mismo que el centro.
    let ratio = 1;
    if (eff.grip.joint.type !== "prismatic") {
      const pivot = vecOf(pose(eff, eff.arm.map((j) => ctx.get().mjd.qpos[j.qadr]), eff.grip.closed).xpos, jawBody);
      let far = 0;
      for (const k of geomsOf(jawBody)) {
        const c = [mjm.geom_aabb[k * 6], mjm.geom_aabb[k * 6 + 1], mjm.geom_aabb[k * 6 + 2]];
        const h = [mjm.geom_aabb[k * 6 + 3], mjm.geom_aabb[k * 6 + 4], mjm.geom_aabb[k * 6 + 5]];
        for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const sz of [-1, 1]) {
          const w = rotate(closed.gxmat, k, [c[0] + sx * h[0], c[1] + sy * h[1], c[2] + sz * h[2]]).map((v, i) => v + closed.gxpos[k * 3 + i]);
          far = Math.max(far, norm(sub(w, pivot)));
        }
      }
      const com = norm(sub(closed.coms[0], pivot));
      if (com > 1e-3 && far > com) ratio = far / com;
    }
    eff.maxWidth = norm(across) * ratio;
  }

  function fk(eff, q) {
    const d = pose(eff, q);
    const x = d.xpos, m = d.xmat, b = eff.tcpBody;
    // Con un dedo fijo, el objeto (de ancho `grasp`) queda entre él y el móvil: el centro se corre hacia el móvil.
    const local = eff.oneJaw && eff.closeLocal ? eff.offset.map((v, i) => v - eff.closeLocal[i] * (eff.grasp ?? 0.0125)) : eff.offset;
    const p = vecOf(x, b).map((v, i) => v + rotate(m, b, local)[i]);
    const axis = eff.axisLocal ? rotate(m, b, eff.axisLocal) : eff.handBody >= 0 ? sub(p, vecOf(x, eff.handBody)) : DOWN;
    const close = eff.closeLocal ? rotate(m, b, eff.closeLocal) : null;
    return { p, axis: unit(axis), close };
  }

  /** Lo que falta para la meta: posición, inclinación y (si se pidió) la dirección en que cierran los dedos. */
  function residual(eff, q, goal, [tiltW, yawW], yaw) {
    const { p, axis, close } = fk(eff, q);
    const r = sub(p, goal);
    if (tiltW > 0) r.push(...sub(axis, DOWN).map((v) => v * tiltW));
    // Los dedos tienen que cerrar a lo largo de `yaw` (o justo al revés: da igual): nada de su cierre de costado.
    if (yaw && close && yawW > 0) r.push(dot(close, [-yaw[1], yaw[0], 0]) * yawW);
    return r;
  }

  /** Cinemática inversa (mínimos cuadrados amortiguados), dentro de los límites. */
  function ik(eff, goal, q0, yaw = null) {
    let s;
    for (const w of WEIGHTS) {
      s = ikWeighted(eff, goal, q0, w, yaw);
      if (s.error < 0.003) return s;
    }
    return s;
  }

  function ikWeighted(eff, goal, q0, weights, yaw) {
    const solveFrom = (start) => {
      let q = start.slice();
      for (let it = 0; it < 120; it++) {
        const r = residual(eff, q, goal, weights, yaw);
        if (norm(r.slice(0, 3)) < 5e-4 && norm(r.slice(3)) < 0.002) break;
        const eps = 1e-4, J = r.map(() => new Array(q.length));
        for (let i = 0; i < q.length; i++) {
          const qi = q[i];
          q[i] = qi + eps;
          const ri = residual(eff, q, goal, weights, yaw);
          q[i] = qi;
          for (let k = 0; k < r.length; k++) J[k][i] = (ri[k] - r[k]) / eps;
        }
        const lambda2 = 1e-4;
        const A = J.map((row, a) => J.map((other, b) => row.reduce((s, v, i) => s + v * other[i], 0) + (a === b ? lambda2 : 0)));
        const y = solve(A, r.map((v) => -v));
        for (let i = 0; i < q.length; i++) {
          const dq = clamp(J.reduce((s, row, k) => s + row[i] * y[k], 0), -0.25, 0.25);
          const j = eff.arm[i];
          q[i] = j.lower != null ? clamp(q[i] + dq, j.lower, j.upper) : q[i] + dq;
        }
      }
      const { p, axis, close } = fk(eff, q);
      let yawError = null;
      if (yaw && close) {
        const h = unit([close[0], close[1], 0]);
        yawError = Math.acos(clamp(Math.abs(h[0] * yaw[0] + h[1] * yaw[1]), 0, 1)) * 180 / Math.PI;
      }
      return { q, error: norm(sub(p, goal)), tilt: Math.acos(clamp(-axis[2], -1, 1)) * 180 / Math.PI, yawError };
    };
    let best = solveFrom(q0);
    // Si no llega, prueba desde otras posturas (el medio del rango y algunas al azar).
    for (let k = 0; k < 6 && best.error > 0.004; k++) {
      const seed = eff.arm.map((j) => {
        const lo = j.lower ?? -Math.PI, hi = j.upper ?? Math.PI;
        return k === 0 ? (lo + hi) / 2 : lo + Math.random() * (hi - lo);
      });
      const other = solveFrom(seed);
      if (other.error < best.error) best = other;
    }
    return best;
  }

  /** Un tramo recto de la punta, de `from` a `to`, como lista de posturas (una cada ~1 cm). */
  function line(eff, from, to, q0, speed = JOINT_SPEED, yaw = null) {
    const n = Math.max(1, Math.ceil(norm(sub(to, from)) / 0.01));
    const qs = [q0];
    let q = q0, worst = 0, yawError = null;
    for (let k = 1; k <= n; k++) {
      const goal = from.map((v, i) => v + (to[i] - v) * (k / n));
      const s = ik(eff, goal, q, yaw);
      q = s.q;
      worst = Math.max(worst, s.error);
      yawError = s.yawError;
      qs.push(q);
    }
    const travel = qs.slice(1).reduce((t, q2, k) => t + Math.max(...q2.map((v, i) => Math.abs(v - qs[k][i]))), 0);
    return { kind: "path", qs, duration: Math.max(0.4, travel / speed), error: worst, end: to, yawError };
  }

  // ---------- de la cámara a la mesa ----------
  /** Un píxel de la imagen de una cámara (de `width` de ancho) → el punto donde su rayo corta z = `height`. */
  function pointFromPixel(cameraName, x, y, width, height = 0) {
    const { cameras, root } = ctx.get();
    const c = cameras.find((k) => k.name === cameraName);
    if (!c) throw new Error(`There's no camera called "${cameraName}".`);
    const h = Math.round(width / c.cam.aspect);
    if (x < 0 || y < 0 || x > width || y > h) throw new Error(`The pixel (${x}, ${y}) is outside the ${width}×${h} image.`);
    c.cam.updateMatrixWorld(true);
    root.updateMatrixWorld(true);
    const ray = new THREE.Raycaster();
    ray.setFromCamera(new THREE.Vector2((x / width) * 2 - 1, 1 - (y / h) * 2), c.cam);
    const a = root.worldToLocal(ray.ray.origin.clone());
    const b = root.worldToLocal(ray.ray.origin.clone().add(ray.ray.direction));
    const d = b.clone().sub(a);
    if (Math.abs(d.z) < 1e-6) throw new Error("That pixel looks at the horizon, not the table.");
    const t = (height - a.z) / d.z;
    if (t <= 0) throw new Error("That pixel doesn't look at the table.");
    return [a.x + d.x * t, a.y + d.y * t, height];
  }

  // ---------- habilidades ----------
  function armQ(eff) {
    const { mjd } = ctx.get();
    return eff.arm.map((j) => mjd.qpos[j.qadr]);
  }

  /** Arma los pasos de una habilidad. Si algún tramo no se alcanza, no se mueve nada. */
  function plan(spec, speed = JOINT_SPEED) {
    const eff = effector();
    if (eff.arm.length < 3) throw new Error("This robot doesn't have an arm I can steer (needs 3+ motorized joints up to the tip).");
    let q = armQ(eff);
    let here = fk(eff, q).p;
    const steps = [], reach = [], notes = {};
    let yaw = null;   // la dirección (horizontal) en que tienen que cerrar los dedos, si se pidió
    const go = (to) => {
      const seg = line(eff, here, to, q, speed, yaw);
      reach.push(seg.error);
      if (yaw && seg.yawError != null) notes.yaw_error_deg = Math.round(seg.yawError);
      steps.push(seg);
      q = seg.qs[seg.qs.length - 1];
      here = to;
    };
    const wantYaw = (v) => {
      if (!v || !eff.closeLocal) return;
      const n = Math.hypot(v[0], v[1]);
      if (n > 1e-6) yaw = [v[0] / n, v[1] / n];
    };
    // Al dejar algo sin pedir orientación: los dedos siguen cerrando como ahora (el objeto no gira en el aire).
    const keepYaw = () => {
      const c = fk(eff, q).close;
      if (c && Math.hypot(c[0], c[1]) > 0.3) wantYaw([c[0], c[1]]);
    };
    const grip = (open, hold = 0, width = null) => {
      if (!eff.grip) return;
      let value = open ? eff.grip.open : eff.grip.closed;
      // Abrir solo lo necesario para el objeto (su ancho + 1,5 cm), no todo: un dedo que abre de más choca con lo
      // que hay al lado o barre el objeto al bajar.
      if (open && width != null && eff.maxWidth) {
        const f = clamp((width + 0.015) / eff.maxWidth, 0.25, 1);
        value = eff.grip.closed + f * (eff.grip.open - eff.grip.closed);
      }
      steps.push({ kind: "grip", value, hold });
    };
    // Primero subir si está muy bajo, para no arrastrar nada por la mesa.
    if (here[2] < CLEARANCE * 0.75) go([here[0], here[1], CLEARANCE]);

    if ((spec.type === "pick" || spec.type === "place") && !eff.grip) {
      throw new Error("This robot has no gripper I can recognize (set «effector.gripper» in its profile).");
    }
    if (spec.type === "pick") {
      const h = clamp(spec.height ?? 0.025, 0.005, 0.2);
      const [x, y] = spec.point;
      wantYaw(spec.yaw);
      eff.grasp = clamp((spec.width ?? 0.025) / 2, 0.004, (eff.maxWidth ?? 0.05) / 2);
      if (spec.width != null && eff.maxWidth != null) {
        notes.object_width_cm = Math.round(spec.width * 1000) / 10;
        notes.gripper_max_opening_cm = Math.round(eff.maxWidth * 1000) / 10;
        if (spec.width > eff.maxWidth) notes.warning = "The object looks wider than the gripper opens.";
      }
      const grasp = Math.max(0.006, h * 0.5);
      grip(true, 0, spec.width ?? null);
      go([x, y, h + CLEARANCE]);
      go([x, y, grasp]);
      grip(false, 0.25);
      steps.push({ kind: "check", key: "holding_after_close" });
      go([x, y, h + CLEARANCE + 0.02]);
      steps.push({ kind: "check", key: "holding" });
    } else if (spec.type === "place") {
      const surface = clamp(spec.surface ?? 0, 0, 0.3), h = clamp(spec.height ?? 0.025, 0.005, 0.2);
      const [x, y] = spec.point;
      const release = surface + Math.max(0.006, h * 0.5) + 0.006;
      if (spec.yaw) wantYaw(spec.yaw); else keepYaw();
      go([x, y, release + h + CLEARANCE]);
      go([x, y, release]);
      grip(true, 0.3, (eff.grasp ?? 0.0125) * 2);
      go([x, y, release + CLEARANCE]);
      steps.push({ kind: "check", key: "holding" });
    } else if (spec.type === "reach") {
      if (spec.close) grip(false);
      go(spec.point);
    } else if (spec.type === "gripper") {
      grip(spec.open, 0.2);
      steps.push({ kind: "check", key: "holding" });
    } else {
      throw new Error(`Unknown skill: ${spec.type}`);
    }
    const worst = Math.max(0, ...reach);
    return { eff, steps, worst, notes };
  }

  /** ¿La pinza quedó trabada en algo? (no llegó a cerrarse del todo). */
  function holding(eff) {
    if (!eff.grip) return null;
    const { mjd } = ctx.get();
    const { joint, open, closed } = eff.grip;
    const q = mjd.qpos[joint.qadr];
    if (Math.abs(joint.target - closed) > Math.abs(open - closed) * 0.5) return false;  // está abierta
    return Math.abs(q - closed) > Math.abs(open - closed) * 0.06;
  }

  function finish(extra = {}) {
    const t = task;
    task = null;
    const { p } = fk(t.eff, armQ(t.eff));
    t.resolve({ ...t.result, ...extra, tip_cm: p.map((v) => Math.round(v * 1000) / 10) });
  }

  /** Avanza la habilidad en curso (una vez por paso de física). */
  function tick(dt) {
    if (!task) return;
    const step = task.steps[task.i];
    if (!step) return finish({ done: true });
    task.t += dt;
    const { mjd } = ctx.get();
    if (step.kind === "path") {
      const s = smooth(Math.min(1, task.t / step.duration));
      const f = s * (step.qs.length - 1), k = Math.min(step.qs.length - 2, Math.floor(f)), u = f - k;
      const a = step.qs[k], b = step.qs[k + 1] ?? a;
      task.eff.arm.forEach((j, i) => { j.target = a[i] + (b[i] - a[i]) * u; });
      const settled = task.eff.arm.every((j, i) => Math.abs(mjd.qpos[j.qadr] - b[i]) < 0.03);
      if (task.t >= step.duration && (settled || task.t > step.duration + 0.8)) next();
    } else if (step.kind === "grip") {
      const g = task.eff.grip.joint;
      const closing = step.value === task.eff.grip.closed;
      if (!task.gripHeld) {
        // Al cerrar, el objetivo avanza a velocidad limitada (todo el recorrido en ~0,8 s): no golpea el objeto.
        const span = Math.abs(task.eff.grip.open - task.eff.grip.closed), from = task.gripFrom ??= mjd.qpos[g.qadr];
        const travel = Math.min(Math.abs(step.value - from), (span / 0.8) * task.t);
        g.target = closing ? from + Math.sign(step.value - from) * travel : step.value;
      }
      const still = Math.abs(mjd.qvel[g.dadr]) < 0.05;
      task.still = still ? (task.still || 0) + dt : 0;
      // Como una pinza real: al cerrar, cuando se frena contra algo, sostiene con una fuerza moderada (la mitad de
      // la de su motor) en vez de apretar con todo: un URDF con un motor muy fuerte no escupe lo que agarra.
      if (closing && !task.gripHeld && task.t > 0.2 && task.still > 0.05) {
        const q = mjd.qpos[g.qadr], room = step.value - q;
        if (Math.abs(room) > 1e-3 && g.kp > 0) {
          g.target = q + Math.sign(room) * Math.min(Math.abs(room), 0.5 * (g.fmax ?? 1) / g.kp);
          task.gripHeld = true;
        }
      }
      if ((task.t > 0.2 && task.still > 0.1 + step.hold && (!closing || task.gripHeld || g.target === step.value)) || task.t > 2) next();
    } else if (step.kind === "check") {
      task.result[step.key] = holding(task.eff);
      next();
    }
  }

  function next() { task.i++; task.t = 0; task.still = 0; task.gripHeld = false; task.gripFrom = null; }

  /**
   * Planifica sin mover nada y devuelve la trayectoria entera, para que la ejecute otro (el robot real):
   * filas [t, valor de cada articulación de `names`] en radianes, desde la pose actual.
   * opts: { names, speed (rad/s), gripSeconds }.
   */
  function timeline(spec, { names, speed = 0.55, gripSeconds = 1.2 } = {}) {
    const { mjd, model } = ctx.get();
    const { eff, steps, worst, notes } = plan(spec, speed);
    const result = { ok: worst <= 0.012, reach_error_cm: Math.round(worst * 1000) / 10, ...notes };
    if (!result.ok) {
      return { ...result, reason: "out_of_reach", message: `The arm can't get there (it would miss by ${(worst * 100).toFixed(1)} cm).` };
    }
    const byName = new Map(model.joints.map((j) => [j.name, j]));
    const pose = Object.fromEntries(names.map((n) => [n, byName.get(n)?.qadr >= 0 ? mjd.qpos[byName.get(n).qadr] : 0]));
    const rows = [], row = (t) => rows.push([t, ...names.map((n) => pose[n])]);
    let t = 0;
    row(t);
    for (const step of steps) {
      if (step.kind === "path") {
        const n = step.qs.length - 1;
        for (let k = 1; k <= n; k++) {
          // Arranca y frena suave: los puntos se reparten en el tiempo como la curva smoothstep.
          const s = k / n;
          let lo = 0, hi = 1;
          for (let it = 0; it < 30; it++) { const m = (lo + hi) / 2; if (smooth(m) < s) lo = m; else hi = m; }
          eff.arm.forEach((j, i) => { pose[j.name] = step.qs[k][i]; });
          row(t + step.duration * hi);
        }
        t += step.duration;
      } else if (step.kind === "grip") {
        pose[eff.grip.joint.name] = step.value;
        for (const f of eff.grip.followers) if (f.name in pose) pose[f.name] = (f.mimic.multiplier ?? 1) * step.value + (f.mimic.offset ?? 0);
        t += gripSeconds;
        row(t);
        if (step.hold) { t += step.hold; row(t); }
      }
    }
    return { ...result, names, rows, seconds: Math.round(t * 10) / 10,
      gripper: eff.grip ? { joint: eff.grip.joint.name, open: eff.grip.open, closed: eff.grip.closed } : null };
  }

  /**
   * El espacio de trabajo de este brazo, medido con su cinemática: hasta dónde llega (reach), hacia dónde mira
   * (la dirección de la punta en reposo) y `count` puntos alcanzables, repartidos en ancho, fondo y alto, para
   * calibrar una cámara. Sirve para ubicar cosas a la escala de cada robot.
   */
  function workspace(count = 8) {
    const { model } = ctx.get();
    const eff = effector();
    const q = armQ(eff);
    const d = pose(eff, q);
    const base = vecOf(d.xpos, model.links.get(model.rootLink)?.body ?? 0);
    // Alcance: la suma de los tramos de la cadena (de articulación en articulación hasta la punta).
    const chain = [...eff.arm.map((j) => vecOf(d.xpos, model.links.get(j.child).body)), fk(eff, q).p];
    let reach = 0;
    for (let i = 1; i < chain.length; i++) reach += norm(sub(chain[i], chain[i - 1]));
    const tip = sub(fk(eff, q).p, base);
    const flat = Math.hypot(tip[0], tip[1]);
    const azimuth = flat > 0.02 ? Math.atan2(tip[1], tip[0]) : 0;
    const dist = clamp(flat, 0.35 * reach, 0.6 * reach);
    const points = [];
    for (const [r, a, z] of [[0.8, -1, 0.12], [1.2, 1, 0.12], [1.2, -1, 0.45], [0.8, 1, 0.45],
                             [1.0, 0, 0.25], [0.9, -0.5, 0.6], [1.3, 0, 0.18], [1.0, 1.4, 0.3], [0.75, 0, 0.3], [1.1, -1.4, 0.3]]) {
      if (points.length >= count) break;
      const ang = azimuth + a * 0.35;
      const goal = [base[0] + Math.cos(ang) * dist * r, base[1] + Math.sin(ang) * dist * r, base[2] + z * reach * 0.6];
      if (ik(eff, goal, q).error < 0.004) points.push(goal);
    }
    return { base, reach, azimuth, distance: dist, points };
  }

  /** Dónde está ahora el centro del agarre (m, mundo). */
  function tip() {
    const eff = effector();
    return fk(eff, armQ(eff)).p;
  }

  return {
    pointFromPixel,
    tick,
    timeline,
    tip,
    workspace,
    /** Empieza una habilidad; la promesa se cumple al terminar (o al cancelarla) con cómo salió. */
    run(spec) {
      if (task) this.cancel("replaced by a new skill");
      const { eff, steps, worst, notes } = plan(spec);
      if (worst > 0.012) {
        return Promise.resolve({ done: false, reason: "out_of_reach",
          message: `The arm can't get there (it would miss by ${(worst * 100).toFixed(1)} cm).` });
      }
      return new Promise((resolve) => {
        task = { eff, steps, i: 0, t: 0, still: 0, resolve, result: { done: false, reach_error_cm: Math.round(worst * 1000) / 10, ...notes } };
      });
    },
    cancel(reason = "stopped") {
      if (!task) return;
      // Se queda donde está.
      const { mjd } = ctx.get();
      for (const j of task.eff.arm) j.target = mjd.qpos[j.qadr];
      finish({ done: false, reason });
    },
    get busy() { return !!task; },
    effector: () => {
      const e = effector(), r = (v) => v && v.map((x) => Math.round(x * 1000) / 1000);
      const w = (() => { try { return workspace(0); } catch { return null; } })();
      return { tip: e.tcp, arm: e.arm.map((j) => j.name), gripper: e.grip?.joint.name ?? null, offset: r(e.offset), axis: r(e.axisLocal),
        close_axis: r(e.closeLocal), max_opening_cm: e.maxWidth != null ? Math.round(e.maxWidth * 1000) / 10 : null,
        // Para describir el robot a la IA: cuántos dedos se mueven, si puede girar la pinza y su alcance.
        fingers: e.grip ? 1 + e.grip.followers.length : 0, one_jaw: !!e.oneJaw || (e.grip ? e.grip.followers.length === 0 : false),
        can_turn: !!e.closeLocal, reach_cm: w ? Math.round(w.reach * 100) : null,
        facing_deg: w ? Math.round(w.azimuth * 180 / Math.PI) : null };
    },
  };
}
