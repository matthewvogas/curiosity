import { useEffect, useState } from "react";
import { Button, Icon, Section, Slider, Switch, Tabs } from "@/components/ui";
import type { SceneObject } from "@/types/robot-types";
import s from "./scene-controls.module.css";

type Shape = "box" | "sphere" | "cylinder";
type Changes = Partial<Pick<SceneObject, "pos" | "yaw" | "mass" | "color" | "name" | "fixed">>;

const SHAPE_NAMES: Record<string, string> = { box: "Box", sphere: "Sphere", cylinder: "Cylinder", capsule: "Capsule" };
const nameOf = (o: SceneObject) => o.name || SHAPE_NAMES[o.shape] || "Object";

/** Lo que mide un objeto (largo × ancho × alto, m), de sus piezas o de su forma. */
function extent(o: SceneObject): number[] {
  const parts = o.parts?.length ? o.parts : [{ shape: o.shape, size: o.size, pos: [0, 0, 0] }];
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (const p of parts) {
    const [a, b = a, c = b] = p.size;
    const half = p.shape === "sphere" ? [a, a, a] : p.shape === "cylinder" || p.shape === "capsule" ? [a, a, b / 2] : [a / 2, b / 2, c / 2];
    for (let i = 0; i < 3; i++) {
      lo[i] = Math.min(lo[i], p.pos[i] - half[i]);
      hi[i] = Math.max(hi[i], p.pos[i] + half[i]);
    }
  }
  return lo.map((v, i) => hi[i] - v);
}

function sizeText(o: SceneObject): string {
  const d = extent(o);
  if (Math.max(...d) >= 1) return d.map((v) => +v.toFixed(2)).join(" × ") + " m";
  return d.map((v) => +(v * 100).toFixed(1)).join(" × ") + " cm";
}

const weight = (kg: number) => (kg >= 1 ? `${+kg.toFixed(kg >= 10 ? 0 : 1)} kg` : `${Math.round(kg * 1000)} g`);

/**
 * Escena: los objetos (cada uno se abre para ver y cambiar dónde está, su giro, peso, color y si está fijo),
 * cómo moverlos con el mouse y agregar una forma simple. Para crear cosas reales («un escritorio»), el chat.
 */
export function SceneControls({ objects, positions, yaws, open, onOpen, onUpdate, onAdd, onRemove }: {
  objects: SceneObject[];
  /** Dónde está cada objeto ahora (m, marco de la base). */
  positions: Record<number, number[]>;
  /** Su giro actual (grados), que la pantalla pide al abrir un objeto. */
  yaws: Record<number, number>;
  /** El objeto abierto en la lista (el seleccionado, también con un clic en la escena). */
  open: number | null;
  onOpen: (id: number | null) => void;
  onUpdate: (id: number, changes: Changes) => void;
  onAdd: (object: SceneObject) => void;
  onRemove: (id: number) => void;
}) {
  const [shape, setShape] = useState<Shape>("box");
  const [sizeCM, setSizeCM] = useState(3);
  const [massG, setMassG] = useState(20);
  const [color, setColor] = useState("#e3572e");

  const newObject = (): SceneObject => {
    const m = sizeCM / 100;
    const size = shape === "sphere" ? [m / 2] : shape === "cylinder" ? [m / 2, m] : [m, m, m];
    return { id: 0, shape, size, mass: massG / 1000, color, pos: [0, 0, 0], yaw: 0, fixed: false, name: "", drop: true };
  };

  return (
    <div className={s.panel}>
      <Section title={`Objects${objects.length ? ` · ${objects.length}` : ""}`}>
        {objects.length === 0 ? (
          <div className={s.empty}>
            Nothing on the table yet. Add a shape below, or ask in the chat: <em>“put a coffee mug on the table”</em>.
          </div>
        ) : (
          <div className={s.list}>
            {objects.map((o) => (
              <ObjectRow
                key={o.id}
                object={o}
                position={positions[o.id] ?? o.pos}
                yaw={yaws[o.id] ?? o.yaw}
                open={open === o.id}
                onToggle={() => onOpen(open === o.id ? null : o.id)}
                onUpdate={(c) => onUpdate(o.id, c)}
                onRemove={() => onRemove(o.id)}
              />
            ))}
          </div>
        )}
        <div className={s.hint}>
          <Icon name="hand" size={13} />
          <span>Click an object to select it. Drag to move it, scroll while dragging to lift it, Shift + scroll or Q / E to turn it.</span>
        </div>
      </Section>

      <Section title="Add a shape">
        <div className={s.form}>
          <Tabs<Shape>
            variant="segmented"
            tabs={[{ id: "box", title: "Box" }, { id: "sphere", title: "Sphere" }, { id: "cylinder", title: "Cylinder" }]}
            value={shape}
            onChange={setShape}
          />
          <LabeledSlider title="Size" value={sizeCM} min={1} max={30} format={(v) => `${v.toFixed(1)} cm`} onChange={setSizeCM} />
          <LabeledSlider title="Mass" value={massG} min={1} max={2000} format={(v) => weight(v / 1000)} onChange={setMassG} />
          <div className={s.row}>
            <label className={s.colorLabel}>
              Color
              <input type="color" className={s.color} value={color} onChange={(e) => setColor(e.target.value)} />
            </label>
            <Button variant="secondary" size="small" icon="add" onClick={() => onAdd(newObject())}>
              Drop on the table
            </Button>
          </div>
        </div>
      </Section>
    </div>
  );
}

/** Un objeto de la lista: cerrado, su resumen; abierto, todo lo que se puede cambiar. */
function ObjectRow({ object: o, position, yaw, open, onToggle, onUpdate, onRemove }: {
  object: SceneObject;
  position: number[];
  yaw: number;
  open: boolean;
  onToggle: () => void;
  onUpdate: (c: Changes) => void;
  onRemove: () => void;
}) {
  const cm = position.map((v) => v * 100);
  const swatch = o.parts?.[0]?.color ?? o.color;
  return (
    <div className={s.object} data-open={open}>
      <button type="button" className={s.objectHead} onClick={onToggle} aria-expanded={open}>
        <span className={s.chevron} data-open={open}>
          <Icon name="chevron" size={12} />
        </span>
        <span className={s.swatch} style={{ background: swatch }} />
        <span className={s.objectText}>
          <span className={s.name}>{nameOf(o)}</span>
          <span className={s.meta}>
            {sizeText(o)} · {weight(o.mass)}
            {o.fixed ? " · fixed" : ""}
          </span>
        </span>
        <span className={s.coords}>{cm.map((v) => v.toFixed(0)).join(", ")}</span>
      </button>

      {open && (
        <div className={s.detail}>
          <Line label="Name">
            <TextCell value={o.name} placeholder={SHAPE_NAMES[o.shape] ?? "Object"} onCommit={(name) => onUpdate({ name })} />
          </Line>
          <Line label="Position" unit="cm">
            <div className={s.triple}>
              {["x", "y", "z"].map((axis, i) => (
                <NumberCell
                  key={axis}
                  prefix={axis}
                  value={cm[i]}
                  digits={1}
                  onCommit={(v) => onUpdate({ pos: cm.map((c, j) => (j === i ? v : c) / 100) })}
                />
              ))}
            </div>
          </Line>
          <Line label="Rotation" unit="°">
            <NumberCell value={yaw} digits={0} onCommit={(v) => onUpdate({ yaw: v })} />
          </Line>
          <Line label="Mass" unit={o.mass >= 1 ? "kg" : "g"}>
            <NumberCell
              value={o.mass >= 1 ? o.mass : o.mass * 1000}
              digits={o.mass >= 1 ? 2 : 0}
              min={0.001}
              onCommit={(v) => onUpdate({ mass: o.mass >= 1 ? v : v / 1000 })}
            />
          </Line>
          <Line label="Color">
            <input type="color" className={s.color} value={swatch} onChange={(e) => onUpdate({ color: e.target.value })} />
          </Line>
          <Line label="Fixed in place">
            <Switch on={o.fixed} onChange={(fixed) => onUpdate({ fixed })} label="Fixed in place" />
          </Line>
          <div className={s.detailFoot}>
            <Button size="small" variant="ghost" icon="trash" onClick={onRemove}>
              Remove
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function Line({ label, unit, children }: { label: string; unit?: string; children: React.ReactNode }) {
  return (
    <div className={s.line}>
      <span className={s.lineLabel}>
        {label}
        {unit && <span className={s.unit}>{unit}</span>}
      </span>
      <div className={s.lineValue}>{children}</div>
    </div>
  );
}

/** Un número que se edita y se aplica con Enter o al salir del campo (Esc lo deja como estaba). */
function NumberCell({ value, prefix, digits, min, onCommit }: { value: number; prefix?: string; digits: number; min?: number; onCommit: (v: number) => void }) {
  const shown = Number.isFinite(value) ? value.toFixed(digits) : "0";
  const [draft, setDraft] = useState<string | null>(null);
  useEffect(() => setDraft(null), [shown]);
  const commit = () => {
    if (draft == null) return;
    const v = Number(draft.replace(",", "."));
    setDraft(null);
    if (Number.isFinite(v) && v.toFixed(digits) !== shown) onCommit(min != null ? Math.max(min, v) : v);
  };
  return (
    <label className={s.cell}>
      {prefix && <span className={s.cellPrefix}>{prefix}</span>}
      <input
        className={s.cellInput}
        inputMode="decimal"
        value={draft ?? shown}
        onChange={(e) => setDraft(e.target.value)}
        onFocus={(e) => e.currentTarget.select()}
        onBlur={commit}
        onKeyDown={(e) => {
          if (e.key === "Enter") e.currentTarget.blur();
          if (e.key === "Escape") {
            setDraft(null);
            e.currentTarget.blur();
          }
        }}
      />
    </label>
  );
}

function TextCell({ value, placeholder, onCommit }: { value: string; placeholder: string; onCommit: (v: string) => void }) {
  const [draft, setDraft] = useState<string | null>(null);
  return (
    <input
      className={s.textCell}
      value={draft ?? value}
      placeholder={placeholder}
      spellCheck={false}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => {
        if (draft != null && draft.trim() !== value) onCommit(draft.trim());
        setDraft(null);
      }}
      onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
    />
  );
}

function LabeledSlider({ title, value, min, max, format, onChange }: {
  title: string;
  value: number;
  min: number;
  max: number;
  format: (v: number) => string;
  onChange: (v: number) => void;
}) {
  return (
    <div className={s.slider}>
      <div className={s.sliderHead}>
        <span>{title}</span>
        <span className={s.value}>{format(value)}</span>
      </div>
      <Slider value={value} min={min} max={max} onChange={onChange} />
    </div>
  );
}
