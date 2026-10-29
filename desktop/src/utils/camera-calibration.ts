/**
 * Calibración de una cámara fija respecto del robot, sin patrones ni medidas: la punta de la pinza se pone en
 * varios lugares (su posición 3D sale de la cinemática del robot) y se marca dónde se ve en la imagen. Con 6 o
 * más pares se calcula la proyección de la cámara (DLT, 3×4) y con ella un píxel se convierte en un rayo que
 * corta la mesa. Sirve para cualquier robot y cualquier cámara. Coordenadas de imagen normalizadas (0…1), así
 * no depende del tamaño de cada foto.
 */
export type CalibrationPair = {
  /** m, marco de la base del robot */
  point: number[];
  /** 0…1 (x a la derecha, y hacia abajo) */
  pixel: number[];
};

const range = (n: number) => Array.from({ length: n }, (_, i) => i);
const sum = (xs: number[]) => xs.reduce((a, b) => a + b, 0);

export const CameraCalibration = {
  /** La proyección (12 números, fila por fila) y su error medio al reproyectar los pares, en fracción del ancho. */
  solve(pairs: CalibrationPair[]): { matrix: number[]; error: number } | null {
    if (pairs.length < 6) return null;
    const n = pairs.length;
    // Normalización de Hartley: centrar y escalar, para que el sistema esté bien condicionado.
    const c3 = range(3).map((i) => sum(pairs.map((p) => p.point[i])) / n);
    const s3 = Math.sqrt(3) / Math.max(1e-9, sum(pairs.map((p) => Math.sqrt(sum(range(3).map((k) => (p.point[k] - c3[k]) ** 2))))) / n);
    const c2 = range(2).map((i) => sum(pairs.map((p) => p.pixel[i])) / n);
    const s2 = Math.sqrt(2) / Math.max(1e-9, sum(pairs.map((p) => Math.sqrt(sum(range(2).map((k) => (p.pixel[k] - c2[k]) ** 2))))) / n);

    const ata = range(12).map(() => new Array<number>(12).fill(0));
    for (const p of pairs) {
      const X = range(3).map((k) => (p.point[k] - c3[k]) * s3);
      const u = (p.pixel[0] - c2[0]) * s2;
      const v = (p.pixel[1] - c2[1]) * s2;
      const rows = [
        [X[0], X[1], X[2], 1, 0, 0, 0, 0, -u * X[0], -u * X[1], -u * X[2], -u],
        [0, 0, 0, 0, X[0], X[1], X[2], 1, -v * X[0], -v * X[1], -v * X[2], -v],
      ];
      for (const r of rows) for (let i = 0; i < 12; i++) for (let j = 0; j < 12; j++) ata[i][j] += r[i] * r[j];
    }
    const e = smallestEigenvector(ata);
    // Deshacer la normalización: P = T2⁻¹ · Pn · T3.
    const pn = [[e[0], e[1], e[2], e[3]], [e[4], e[5], e[6], e[7]], [e[8], e[9], e[10], e[11]]];
    const t3 = [[s3, 0, 0, -s3 * c3[0]], [0, s3, 0, -s3 * c3[1]], [0, 0, s3, -s3 * c3[2]], [0, 0, 0, 1]];
    const t2inv = [[1 / s2, 0, c2[0]], [0, 1 / s2, c2[1]], [0, 0, 1]];
    let flat = multiply(t2inv, multiply(pn, t3)).flat();
    // Signo: que los puntos que la cámara ve tengan profundidad positiva (así se sabe qué está delante).
    if (depth(flat, pairs[0].point) < 0) flat = flat.map((x) => -x);
    const error =
      sum(
        pairs.map((pair) => {
          const q = CameraCalibration.project(flat, pair.point);
          return q ? Math.hypot(q[0] - pair.pixel[0], q[1] - pair.pixel[1]) : 1;
        }),
      ) / n;
    return { matrix: flat, error };
  },

  /** Dónde se ve un punto 3D (0…1), o null si queda detrás de la cámara. */
  project(m: number[], x: number[]): number[] | null {
    const h = range(3).map((r) => m[r * 4] * x[0] + m[r * 4 + 1] * x[1] + m[r * 4 + 2] * x[2] + m[r * 4 + 3]);
    if (!(h[2] > 1e-12)) return null;
    return [h[0] / h[2], h[1] / h[2]];
  },

  /** El punto de la mesa (o del plano z = `height`, en m) que se ve en el píxel (0…1). */
  point(m: number[], pixel: number[], height: number): number[] | null {
    const M = [[m[0], m[1], m[2]], [m[4], m[5], m[6]], [m[8], m[9], m[10]]];
    const inv = invert3(M);
    if (!inv) return null;
    const p4 = [m[3], m[7], m[11]];
    const center = range(3).map((r) => -sum(range(3).map((k) => inv[r][k] * p4[k])));
    const d = range(3).map((r) => inv[r][0] * pixel[0] + inv[r][1] * pixel[1] + inv[r][2]);
    if (!(Math.abs(d[2]) > 1e-9)) return null;
    const t = (height - center[2]) / d[2];
    const hit = range(3).map((k) => center[k] + d[k] * t);
    // Tiene que quedar delante de la cámara (si no, ese píxel no mira la mesa).
    return depth(m, hit) > 0 ? hit : null;
  },
};

function depth(m: number[], x: number[]): number {
  return m[8] * x[0] + m[9] * x[1] + m[10] * x[2] + m[11];
}

// ---------- Álgebra chica ----------

function multiply(a: number[][], b: number[][]): number[][] {
  return a.map((row) => range(b[0].length).map((j) => sum(row.map((_, k) => row[k] * b[k][j]))));
}

function invert3(m: number[][]): number[][] | null {
  const det =
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
    m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
    m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  if (!(Math.abs(det) > 1e-15)) return null;
  const c = [
    [m[1][1] * m[2][2] - m[1][2] * m[2][1], m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1]],
    [m[1][2] * m[2][0] - m[1][0] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2]],
    [m[1][0] * m[2][1] - m[1][1] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]],
  ];
  return c.map((r) => r.map((x) => x / det));
}

/** El autovector del autovalor más chico de una matriz simétrica (Jacobi). */
function smallestEigenvector(input: number[][]): number[] {
  const a = input.map((r) => [...r]);
  const n = a.length;
  const v: number[][] = range(n).map((i) => range(n).map((j) => (i === j ? 1 : 0)));
  for (let iter = 0; iter < 100; iter++) {
    let off = 0;
    for (let i = 0; i < n; i++) for (let j = i + 1; j < n; j++) off += a[i][j] * a[i][j];
    if (off < 1e-22) break;
    for (let p = 0; p < n; p++) {
      for (let q = p + 1; q < n; q++) {
        if (!(Math.abs(a[p][q]) > 1e-300)) continue;
        const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
        const t = (theta >= 0 ? 1 : -1) / (Math.abs(theta) + Math.sqrt(theta * theta + 1));
        const c = 1 / Math.sqrt(t * t + 1);
        const s = t * c;
        for (let k = 0; k < n; k++) {
          const akp = a[k][p], akq = a[k][q];
          a[k][p] = c * akp - s * akq;
          a[k][q] = s * akp + c * akq;
        }
        for (let k = 0; k < n; k++) {
          const apk = a[p][k], aqk = a[q][k];
          a[p][k] = c * apk - s * aqk;
          a[q][k] = s * apk + c * aqk;
        }
        for (let k = 0; k < n; k++) {
          const vkp = v[k][p], vkq = v[k][q];
          v[k][p] = c * vkp - s * vkq;
          v[k][q] = s * vkp + c * vkq;
        }
      }
    }
  }
  let i = 0;
  for (let k = 1; k < n; k++) if (a[k][k] < a[i][i]) i = k;
  return range(n).map((k) => v[k][i]);
}
