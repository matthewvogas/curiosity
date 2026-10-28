// Descomposición convexa aproximada de una malla, para colisiones.
//
// El motor de física solo choca formas convexas. Una pieza cóncava (la mandíbula de una pinza, una
// U) envuelta en una sola forma convexa se «rellena» y no puede agarrar nada. Aquí, si la malla es
// bastante cóncava (su volumen es mucho menor que el de su envolvente), se parte en varias regiones
// compactas (k-means sobre los triángulos) y cada una lleva su propia envolvente. Las regiones
// comparten los vértices de sus bordes, así que no quedan huecos entre ellas.

import * as THREE from "three";
import { ConvexGeometry } from "three/addons/geometries/ConvexGeometry.js";

const MAX_POINTS = 2000;   // por envolvente: basta una muestra

/** Vértices y triángulos de un objeto, en el marco `matrix` (el del cuerpo rígido). */
export function triangles(object3d, matrix) {
  const pos = [], tris = [], v = new THREE.Vector3();
  object3d.updateMatrixWorld(true);
  object3d.traverse((o) => {
    if (!o.isMesh) return;
    const g = o.geometry, p = g.attributes.position, m = new THREE.Matrix4().multiplyMatrices(matrix, o.matrixWorld);
    const offset = pos.length / 3;
    for (let i = 0; i < p.count; i++) { v.fromBufferAttribute(p, i).applyMatrix4(m); pos.push(v.x, v.y, v.z); }
    if (g.index) for (let i = 0; i < g.index.count; i++) tris.push(offset + g.index.getX(i));
    else for (let i = 0; i < p.count; i++) tris.push(offset + i);
  });
  return { pos: new Float32Array(pos), tris: new Uint32Array(tris) };
}

function sample(points) {
  if (points.length / 3 <= MAX_POINTS) return points;
  const step = Math.ceil(points.length / 3 / MAX_POINTS), out = [];
  for (let i = 0; i < points.length; i += 3 * step) out.push(points[i], points[i + 1], points[i + 2]);
  return new Float32Array(out);
}

function signedVolume(pos, tris) {
  let v = 0;
  for (let t = 0; t < tris.length; t += 3) {
    const a = tris[t] * 3, b = tris[t + 1] * 3, c = tris[t + 2] * 3;
    v += pos[a] * (pos[b + 1] * pos[c + 2] - pos[b + 2] * pos[c + 1])
       - pos[a + 1] * (pos[b] * pos[c + 2] - pos[b + 2] * pos[c])
       + pos[a + 2] * (pos[b] * pos[c + 1] - pos[b + 1] * pos[c]);
  }
  return Math.abs(v / 6);
}

function hullVolume(points) {
  try {
    const vs = [];
    for (let i = 0; i < points.length; i += 3) vs.push(new THREE.Vector3(points[i], points[i + 1], points[i + 2]));
    const g = new ConvexGeometry(vs);
    const p = g.attributes.position.array, idx = [...Array(p.length / 3).keys()];
    return signedVolume(p, idx);
  } catch { return 0; }
}

/**
 * Nubes de puntos (una por parte convexa). `maxParts` 1 = una sola envolvente.
 * Devuelve también qué tan cóncava era la malla, para avisar.
 */
export function decompose({ pos, tris }, maxParts = 8) {
  const whole = sample(pos);
  if (maxParts <= 1 || tris.length < 3 * 60) return { parts: [whole], fill: 1 };
  const fill = signedVolume(pos, tris) / Math.max(hullVolume(whole), 1e-12);
  // Mallas abiertas (fill ~0) o casi convexas: una sola envolvente.
  if (!(fill > 0.02) || fill > 0.8) return { parts: [whole], fill };
  const k = Math.min(maxParts, fill > 0.55 ? 3 : fill > 0.35 ? 5 : 8);

  // Centroides de los triángulos.
  const n = tris.length / 3, cx = new Float32Array(n * 3);
  for (let t = 0; t < n; t++) {
    for (let d = 0; d < 3; d++) {
      cx[t * 3 + d] = (pos[tris[t * 3] * 3 + d] + pos[tris[t * 3 + 1] * 3 + d] + pos[tris[t * 3 + 2] * 3 + d]) / 3;
    }
  }
  // Semillas lejanas entre sí (farthest point sampling) y unas vueltas de k-means.
  const centers = [[cx[0], cx[1], cx[2]]];
  const dist = new Float32Array(n).fill(Infinity);
  while (centers.length < k) {
    const c = centers[centers.length - 1];
    let best = 0, bestD = -1;
    for (let t = 0; t < n; t++) {
      const d = (cx[t * 3] - c[0]) ** 2 + (cx[t * 3 + 1] - c[1]) ** 2 + (cx[t * 3 + 2] - c[2]) ** 2;
      if (d < dist[t]) dist[t] = d;
      if (dist[t] > bestD) { bestD = dist[t]; best = t; }
    }
    centers.push([cx[best * 3], cx[best * 3 + 1], cx[best * 3 + 2]]);
  }
  const label = new Uint16Array(n);
  for (let iter = 0; iter < 12; iter++) {
    const sum = centers.map(() => [0, 0, 0, 0]);
    for (let t = 0; t < n; t++) {
      let best = 0, bestD = Infinity;
      for (let c = 0; c < k; c++) {
        const d = (cx[t * 3] - centers[c][0]) ** 2 + (cx[t * 3 + 1] - centers[c][1]) ** 2 + (cx[t * 3 + 2] - centers[c][2]) ** 2;
        if (d < bestD) { bestD = d; best = c; }
      }
      label[t] = best;
      sum[best][0] += cx[t * 3]; sum[best][1] += cx[t * 3 + 1]; sum[best][2] += cx[t * 3 + 2]; sum[best][3]++;
    }
    for (let c = 0; c < k; c++) if (sum[c][3]) centers[c] = [sum[c][0] / sum[c][3], sum[c][1] / sum[c][3], sum[c][2] / sum[c][3]];
  }

  // Vértices de cada región (con los de sus triángulos de borde: las envolventes se tocan).
  const parts = [];
  for (let c = 0; c < k; c++) {
    const seen = new Set(), pts = [];
    for (let t = 0; t < n; t++) {
      if (label[t] !== c) continue;
      for (let s = 0; s < 3; s++) {
        const i = tris[t * 3 + s];
        if (seen.has(i)) continue;
        seen.add(i);
        pts.push(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]);
      }
    }
    if (pts.length >= 12) parts.push(sample(new Float32Array(pts)));
  }
  return { parts: parts.length ? parts : [whole], fill };
}
