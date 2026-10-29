// Objetos de la escena: de una pieza (caja, esfera, cilindro, cápsula) o compuestos de varias (una rueda,
// un escritorio con patas, un cuchillo con hoja y mango). Solo cálculo: sin three.js ni MuJoCo, para que
// lo usen el dibujo (engine.js) y el MJCF (mjcf-build.js) por igual.
//
// Un objeto: { shape, size, color, … } o { parts: [{ shape, size, pos, euler, color }], … }.
//   · Tamaños en metros: caja [largo, ancho, alto] · esfera [radio] · cilindro y cápsula [radio, largo].
//   · pos: dónde va la pieza respecto del centro del objeto (m). euler: giro en grados [x, y, z].
//   · Los cilindros y las cápsulas tienen el eje en z (como en MuJoCo).

export const SHAPES = ["box", "sphere", "cylinder", "capsule"];

/** Las piezas del objeto, siempre como lista (un objeto simple es una sola pieza en su centro). */
export function partsOf(o) {
  const list = Array.isArray(o.parts) && o.parts.length ? o.parts : [{ shape: o.shape, size: o.size, color: o.color }];
  return list.map((p) => ({
    shape: SHAPES.includes(p.shape) ? p.shape : "box",
    size: (Array.isArray(p.size) && p.size.length ? p.size : [0.05, 0.05, 0.05]).map((v) => Math.max(Number(v) || 0, 0.001)),
    pos: Array.isArray(p.pos) && p.pos.length === 3 ? p.pos.map(Number) : [0, 0, 0],
    euler: Array.isArray(p.euler) && p.euler.length === 3 ? p.euler.map(Number) : [0, 0, 0],
    color: p.color || o.color || "#c8a27a",
  }));
}

/** Volumen de una pieza (m³), para repartir la masa del objeto entre sus piezas. */
export function volume(p) {
  const [a, b = a, c = b] = p.size;
  if (p.shape === "sphere") return (4 / 3) * Math.PI * a ** 3;
  if (p.shape === "cylinder") return Math.PI * a * a * b;
  if (p.shape === "capsule") return Math.PI * a * a * b + (4 / 3) * Math.PI * a ** 3;
  return a * b * c;
}

/** Ángulos en grados [x, y, z] (orden XYZ) → cuaternión [x, y, z, w]. */
export function quatFromEuler(deg) {
  const [x, y, z] = deg.map((d) => (d * Math.PI) / 360);
  const [cx, cy, cz, sx, sy, sz] = [Math.cos(x), Math.cos(y), Math.cos(z), Math.sin(x), Math.sin(y), Math.sin(z)];
  return [
    sx * cy * cz + cx * sy * sz,
    cx * sy * cz - sx * cy * sz,
    cx * cy * sz + sx * sy * cz,
    cx * cy * cz - sx * sy * sz,
  ];
}

/** El giro del objeto entero: euler si lo trae, si no el giro alrededor de z (yaw, grados). */
export function objectQuat(o) {
  if (Array.isArray(o.euler) && o.euler.length === 3) return quatFromEuler(o.euler.map(Number));
  return quatFromEuler([0, 0, Number(o.yaw) || 0]);
}

/** Medio tamaño de cada pieza para MuJoCo (con un grosor mínimo: lo muy fino atraviesa el piso). */
export function mujocoSize(p) {
  const min = 0.002;
  if (p.shape === "sphere") return [Math.max(p.size[0], min)];
  if (p.shape === "cylinder" || p.shape === "capsule") return [Math.max(p.size[0], min), Math.max((p.size[1] ?? p.size[0]) / 2, min)];
  return [0, 1, 2].map((i) => Math.max((p.size[i] ?? p.size[0]) / 2, min));
}

/** Rotar un vector por un cuaternión [x, y, z, w]. */
function rotate(q, v) {
  const [x, y, z, w] = q;
  const ix = w * v[0] + y * v[2] - z * v[1], iy = w * v[1] + z * v[0] - x * v[2];
  const iz = w * v[2] + x * v[1] - y * v[0], iw = -x * v[0] - y * v[1] - z * v[2];
  return [ix * w + iw * -x + iy * -z - iz * -y, iy * w + iw * -y + iz * -x - ix * -z, iz * w + iw * -z + ix * -y - iy * -x];
}

/**
 * La caja que envuelve al objeto ya girado, en su propio centro: { half: [x, y, z], radius } (m).
 * Sirve para soltarlo sobre el piso sin que nazca enterrado y para buscarle un lugar libre.
 */
export function bounds(o) {
  const q = objectQuat(o);
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (const p of partsOf(o)) {
    const h = mujocoSize(p);
    const half = p.shape === "sphere" ? [h[0], h[0], h[0]]
      : p.shape === "cylinder" ? [h[0], h[0], h[1]]
      : p.shape === "capsule" ? [h[0], h[0], h[1] + h[0]]
      : h;
    const pq = quatFromEuler(p.euler);
    for (const sx of [-1, 1]) for (const sy of [-1, 1]) for (const sz of [-1, 1]) {
      const corner = rotate(pq, [sx * half[0], sy * half[1], sz * half[2]]);
      const world = rotate(q, [corner[0] + p.pos[0], corner[1] + p.pos[1], corner[2] + p.pos[2]]);
      for (let i = 0; i < 3; i++) { lo[i] = Math.min(lo[i], world[i]); hi[i] = Math.max(hi[i], world[i]); }
    }
  }
  const half = [0, 1, 2].map((i) => (hi[i] - lo[i]) / 2);
  return { half, center: [0, 1, 2].map((i) => (hi[i] + lo[i]) / 2), radius: Math.hypot(half[0], half[1]) };
}
