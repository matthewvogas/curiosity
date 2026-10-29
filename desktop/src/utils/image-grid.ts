import { base64ToBytes, bytesToBase64 } from "./codable";

/**
 * Una foto con cuadrícula y coordenadas en píxeles, para que la IA pueda señalar con precisión (como en el
 * simulador). Recibe y devuelve JPEG en base64 (sin prefijo), con el tamaño de la imagen.
 */
export const ImageGrid = {
  async draw(jpeg: string, step = 64): Promise<{ jpeg: string; width: number; height: number } | null> {
    try {
      const image = await createImageBitmap(new Blob([base64ToBytes(jpeg) as BlobPart], { type: "image/jpeg" }));
      const w = image.width, h = image.height;
      const canvas = new OffscreenCanvas(w, h);
      const ctx = canvas.getContext("2d");
      if (!ctx) return null;
      ctx.drawImage(image, 0, 0);
      image.close();
      // Origen arriba a la izquierda, como cuenta la IA.
      ctx.lineWidth = 1;
      ctx.strokeStyle = "rgba(255,255,255,0.4)";
      for (let x = step; x < w; x += step) {
        ctx.beginPath();
        ctx.moveTo(x + 0.5, 0);
        ctx.lineTo(x + 0.5, h);
        ctx.stroke();
        label(ctx, String(x), x + 2, 2);
      }
      for (let y = step; y < h; y += step) {
        ctx.beginPath();
        ctx.moveTo(0, y + 0.5);
        ctx.lineTo(w, y + 0.5);
        ctx.stroke();
        label(ctx, String(y), 2, y + 2);
      }
      const blob = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.85 });
      return { jpeg: bytesToBase64(new Uint8Array(await blob.arrayBuffer())), width: w, height: h };
    } catch {
      return null;
    }
  },
};

/** Segmentos de cada dígito: a arriba, b arriba-der, c abajo-der, d abajo, e abajo-izq, f arriba-izq, g medio. */
const DIGITS: Record<string, string> = {
  "0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
  "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg",
};

/** Un número sobre un fondo oscuro (dígitos de 7 segmentos: sin depender de fuentes). (left, top) de la caja. */
function label(ctx: OffscreenCanvasRenderingContext2D, text: string, left: number, top: number) {
  const digit = 7, gap = 2;
  ctx.fillStyle = "rgba(0,0,0,0.6)";
  ctx.fillRect(left, top, text.length * (digit + gap) + 4, 13);
  ctx.strokeStyle = "rgba(255,255,255,1)";
  ctx.lineWidth = 1.4;
  ctx.beginPath();
  [...text].forEach((ch, i) => {
    const x = left + 2 + i * (digit + gap), w = digit - 1, hgt = 9;
    const y0 = top + 2, y1 = y0 + hgt, mid = y0 + hgt / 2;
    const segs: Record<string, [number, number, number, number]> = {
      a: [x, y0, x + w, y0], b: [x + w, y0, x + w, mid], c: [x + w, mid, x + w, y1], d: [x, y1, x + w, y1],
      e: [x, mid, x, y1], f: [x, y0, x, mid], g: [x, mid, x + w, mid],
    };
    for (const s of DIGITS[ch] ?? "") {
      const seg = segs[s];
      if (!seg) continue;
      ctx.moveTo(seg[0], seg[1]);
      ctx.lineTo(seg[2], seg[3]);
    }
  });
  ctx.stroke();
}

