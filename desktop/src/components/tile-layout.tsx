import { Children, isValidElement, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import s from "./tile-layout.module.css";

type Rect = { left: number; top: number; width: number; height: number };

/** El rectángulo más grande con esa proporción (ancho/alto) que cabe en la caja, centrado en ella. */
function fit(aspect: number, box: Rect): Rect {
  const width = Math.min(box.width, box.height * aspect);
  const height = width / aspect;
  return { left: box.left + (box.width - width) / 2, top: box.top + (box.height - height) / 2, width, height };
}

/**
 * Dónde va cada vista. Cada una toma la forma de su imagen (sin franjas grises): la destacada lo más grande
 * posible y las demás chicas, en columna a la derecha o en fila abajo, según cuál deje más grande la principal.
 */
export const DEFAULT_SPLIT = 0.24;
const clampSplit = (f: number) => Math.min(0.6, Math.max(0.12, f));

/** Dónde va cada vista y el divisor (línea vertical si las chicas van en columna, horizontal si van en fila). */
type Arrangement = { rects: Rect[]; column: boolean; divider: number | null };

function arrange(aspects: number[], main: number, W: number, H: number, gap: number, split: number): Arrangement {
  const n = aspects.length;
  if (n === 0 || W <= 0 || H <= 0) return { rects: [], column: true, divider: null };
  if (n === 1) return { rects: [fit(aspects[0], { left: 0, top: 0, width: W, height: H })], column: true, divider: null };
  split = clampSplit(split);
  const others = aspects.map((_, i) => i).filter((i) => i !== main);

  // A: columna a la derecha.
  const side = Math.max(W * split, 120);
  const colMain = fit(aspects[main], { left: 0, top: 0, width: W - side - gap, height: H });
  let heights = others.map((i) => side / aspects[i]);
  const colTotal = heights.reduce((a, b) => a + b, 0) + gap * (others.length - 1);
  const colScale = colTotal > H ? (H - gap * (others.length - 1)) / (colTotal - gap * (others.length - 1)) : 1;
  heights = heights.map((h) => h * colScale);
  const colRects: Rect[] = [];
  let y = Math.max(0, colMain.top + (colMain.height - Math.min(colTotal, H)) / 2);
  const colLeft = colMain.left + colMain.width + gap;
  others.forEach((i, k) => {
    const width = heights[k] * aspects[i];
    colRects[i] = { left: colLeft, top: y, width, height: heights[k] };
    y += heights[k] + gap;
  });

  // B: fila abajo.
  const strip = Math.max(H * split, 80);
  const rowMain = fit(aspects[main], { left: 0, top: 0, width: W, height: H - strip - gap });
  let widths = others.map((i) => strip * aspects[i]);
  const rowTotal = widths.reduce((a, b) => a + b, 0) + gap * (others.length - 1);
  const rowScale = rowTotal > W ? (W - gap * (others.length - 1)) / (rowTotal - gap * (others.length - 1)) : 1;
  widths = widths.map((w) => w * rowScale);
  const rowRects: Rect[] = [];
  let x = (W - Math.min(rowTotal, W)) / 2;
  const rowTop = rowMain.top + rowMain.height + gap;
  others.forEach((i, k) => {
    rowRects[i] = { left: x, top: rowTop, width: widths[k], height: widths[k] / aspects[i] };
    x += widths[k] + gap;
  });

  const column = colMain.width * colMain.height >= rowMain.width * rowMain.height;
  const rects = column ? colRects : rowRects;
  rects[main] = column ? colMain : rowMain;
  // Todo el grupo centrado en el espacio disponible.
  const right = Math.max(...rects.map((r) => r.left + r.width)), bottom = Math.max(...rects.map((r) => r.top + r.height));
  const left = Math.min(...rects.map((r) => r.left)), top = Math.min(...rects.map((r) => r.top));
  const dx = (W - (right - left)) / 2 - left, dy = (H - (bottom - top)) / 2 - top;
  const placed = rects.map((r) => ({ ...r, left: r.left + dx, top: r.top + dy }));
  const m = placed[main];
  return { rects: placed, column, divider: column ? m.left + m.width + gap / 2 : m.top + m.height + gap / 2 };
}

/**
 * Acomoda vistas en mosaico (ver `arrange`). Cada hijo se queda en el mismo lugar del DOM y solo cambia su
 * posición, así conserva su identidad al cambiar de lugar (el modelo 3D no se vuelve a cargar al destacarlo).
 * Los hijos necesitan `key` estable; `aspects` es la proporción de cada uno (ancho/alto; 4:3 si no se sabe).
 */
export function TileLayout({ focused, spacing = 10, aspects = [], split = DEFAULT_SPLIT, onSplitChange, children }: {
  focused: number;
  spacing?: number;
  aspects?: number[];
  /** Cuánto ocupan las vistas chicas: fracción del ancho (en columna) o del alto (en fila). */
  split?: number;
  /** Con esto aparece el divisor: se arrastra para cambiar `split`; doble clic vuelve al de siempre. */
  onSplitChange?: (split: number) => void;
  children: ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ width: 800, height: 600 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setSize({ width: el.clientWidth, height: el.clientHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const items = Children.toArray(children).filter(isValidElement);
  const main = Math.min(Math.max(0, focused), items.length - 1);
  const { rects, column, divider } = arrange(items.map((_, i) => (aspects[i] > 0 ? aspects[i] : 4 / 3)), main, size.width, size.height, spacing, split);
  const [dragging, setDragging] = useState(false);

  const startDrag = (e: React.PointerEvent) => {
    if (!onSplitChange || !ref.current) return;
    e.preventDefault();
    const box = ref.current.getBoundingClientRect();
    setDragging(true);
    const move = (ev: PointerEvent) => {
      const at = column ? ev.clientX - box.left : ev.clientY - box.top;
      const total = column ? box.width : box.height;
      onSplitChange(clampSplit((total - at) / total));
    };
    const up = () => {
      setDragging(false);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };

  return (
    <div ref={ref} className={s.layout} data-dragging={dragging} data-axis={column ? "x" : "y"}>
      {items.map((child, i) => (
        <div key={child.key ?? i} className={s.slot} style={rects[i]}>
          {child}
        </div>
      ))}
      {onSplitChange && divider != null && (
        <div
          className={s.divider}
          data-axis={column ? "x" : "y"}
          data-active={dragging}
          style={column ? { left: divider - 7, top: 0, width: 14, height: "100%" } : { top: divider - 7, left: 0, height: 14, width: "100%" }}
          onPointerDown={startDrag}
          onDoubleClick={() => onSplitChange(DEFAULT_SPLIT)}
          title="Drag to resize · double-click to reset"
        />
      )}
    </div>
  );
}

/** Un panel del mosaico: su contenido en un contenedor redondeado, con su nombre. */
export function Tile({ title, focused, onTap, children }: { title: string; focused: boolean; onTap: () => void; children: ReactNode }) {
  return (
    <div className={s.tile} title={focused ? undefined : "View large"}>
      {children}
      <div className={s.title}>{title}</div>
      {/* En los paneles chicos, un clic lo pasa a grande (el 3D grande se sigue pudiendo girar). */}
      {!focused && <button type="button" className={s.cover} aria-label={`View ${title} large`} onClick={onTap} />}
    </div>
  );
}
