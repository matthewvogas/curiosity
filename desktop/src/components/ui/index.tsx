import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Icon, type IconName } from "./icon";
import s from "./ui.module.css";

export { Icon, Logo, type IconName } from "./icon";

const cx = (...c: Array<string | false | null | undefined>) => c.filter(Boolean).join(" ");
export { cx };

type Tone = "green" | "amber" | "red" | "blue" | "neutral";

// ---------- Botones ----------

export function Button({ variant = "secondary", size = "medium", icon, children, className, ...rest }: {
  variant?: "primary" | "secondary" | "ghost" | "danger" | "success";
  size?: "small" | "medium" | "large";
  icon?: IconName;
} & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button type="button" className={cx(s.button, s[variant], size !== "medium" && s[size], className)} {...rest}>
      {icon && <Icon name={icon} size={size === "small" ? 13 : 14} />}
      {children}
    </button>
  );
}

export function IconButton({ icon, label, active, size = 15, className, ...rest }: {
  icon: IconName;
  label: string;
  active?: boolean;
  size?: number;
} & React.ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button type="button" className={cx(s.iconButton, className)} title={label} aria-label={label} data-active={active} {...rest}>
      <Icon name={icon} size={size} />
    </button>
  );
}

// ---------- Pestañas ----------

export function Tabs<T extends string>({ tabs, value, onChange, variant = "pill" }: {
  tabs: { id: T; title: string; icon?: IconName; count?: number }[];
  value: T;
  onChange: (t: T) => void;
  /** pill: botones sueltos · segmented: una cápsula con partes iguales (como en macOS) · underline: subrayadas */
  variant?: "pill" | "segmented" | "underline";
}) {
  const under = variant === "underline";
  const seg = variant === "segmented";
  return (
    <div className={under ? s.underTabs : seg ? s.segmented : s.tabs} role="tablist">
      {tabs.map((t) => (
        <button key={t.id} type="button" role="tab" className={under ? s.underTab : seg ? s.segment : s.tab} data-selected={t.id === value} onClick={() => onChange(t.id)}>
          {t.icon && <Icon name={t.icon} size={14} />}
          {t.title}
          {t.count != null && <span className={s.tabCount}>{t.count}</span>}
        </button>
      ))}
    </div>
  );
}

// ---------- Campos ----------

export function Field({ label, hint, children }: { label?: string; hint?: ReactNode; children: ReactNode }) {
  return (
    <label className={s.field}>
      {label && <span className={s.label}>{label}</span>}
      {children}
      {hint && <span className={s.hint}>{hint}</span>}
    </label>
  );
}

export function TextInput({ className, ...rest }: React.InputHTMLAttributes<HTMLInputElement>) {
  return <input className={cx(s.input, className)} spellCheck={false} autoComplete="off" {...rest} />;
}

export function TextArea({ className, ...rest }: React.TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={cx(s.input, className)} {...rest} />;
}

export function Select<T extends string | number>({ value, options, onChange, className, disabled }: {
  value: T;
  options: { value: T; label: string }[];
  onChange: (v: T) => void;
  className?: string;
  disabled?: boolean;
}) {
  return (
    <select
      className={cx(s.input, s.select, className)}
      value={String(value)}
      disabled={disabled}
      onChange={(e) => {
        const o = options.find((o) => String(o.value) === e.target.value);
        if (o) onChange(o.value);
      }}
    >
      {options.map((o) => (
        <option key={String(o.value)} value={String(o.value)}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

export function Switch({ on, onChange, disabled, label }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean; label?: string }) {
  return (
    <button type="button" role="switch" aria-checked={on} aria-label={label} className={s.switch} data-on={on} disabled={disabled} onClick={() => onChange(!on)} />
  );
}

/** Una fila con texto a la izquierda y un interruptor a la derecha. */
export function SwitchRow({ title, detail, on, onChange, disabled }: { title: string; detail?: string; on: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <div className={s.switchRow}>
      <div>
        <div>{title}</div>
        {detail && <div className={s.hint}>{detail}</div>}
      </div>
      <Switch on={on} onChange={onChange} disabled={disabled} label={title} />
    </div>
  );
}

export function Slider({ value, min, max, step, onChange, disabled }: { value: number; min: number; max: number; step?: number; onChange: (v: number) => void; disabled?: boolean }) {
  const p = max > min ? ((value - min) / (max - min)) * 100 : 0;
  return (
    <input
      type="range"
      className={s.slider}
      style={{ "--p": `${Math.max(0, Math.min(100, p))}%` } as React.CSSProperties}
      value={value}
      min={min}
      max={max}
      step={step ?? "any"}
      disabled={disabled}
      onChange={(e) => onChange(Number(e.target.value))}
    />
  );
}

// ---------- Agrupaciones y estados ----------

export function Section({ title, action, children, className }: { title?: string; action?: ReactNode; children: ReactNode; className?: string }) {
  return (
    <section className={cx(s.section, className)}>
      {(title || action) && (
        <div className={s.sectionHeader}>
          <span>{title}</span>
          {action}
        </div>
      )}
      {children}
    </section>
  );
}

export function Card({ children, padded = true, className, ...rest }: { children: ReactNode; padded?: boolean } & React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div className={cx(s.card, padded && s.cardPadded, className)} {...rest}>
      {children}
    </div>
  );
}

export const Divider = () => <div className={s.divider} />;

export function Badge({ tone = "neutral", icon, children }: { tone?: Tone; icon?: IconName; children: ReactNode }) {
  return (
    <span className={s.badge} data-tone={tone}>
      {icon && <Icon name={icon} size={11} />}
      {children}
    </span>
  );
}

export const StatusDot = ({ tone = "neutral" }: { tone?: Tone }) => <span className={s.dot} data-tone={tone} />;

export const Kbd = ({ children }: { children: ReactNode }) => <kbd className={s.kbd}>{children}</kbd>;

export function Spinner({ size = 14 }: { size?: number }) {
  return <Icon name="spinner" size={size} />;
}

export function Progress({ value }: { value: number }) {
  return (
    <div className={s.progress}>
      <div className={s.progressBar} style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} />
    </div>
  );
}

export function Callout({ tone = "neutral", icon, children }: { tone?: Tone; icon?: IconName; children: ReactNode }) {
  return (
    <div className={s.callout} data-tone={tone}>
      {icon && <Icon name={icon} size={14} style={{ marginTop: 1, flex: "none" }} />}
      <div>{children}</div>
    </div>
  );
}

export function EmptyState({ icon, title, detail, children }: { icon?: IconName; title: string; detail?: ReactNode; children?: ReactNode }) {
  return (
    <div className={s.empty}>
      {icon && (
        <div className={s.emptyIcon}>
          <Icon name={icon} size={18} />
        </div>
      )}
      <div className={s.emptyTitle}>{title}</div>
      {detail && <div className={s.emptyDetail}>{detail}</div>}
      {children}
    </div>
  );
}

// ---------- Diálogo ----------

export function Dialog({ title, onClose, children, footer, width = 560, height }: {
  title?: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  width?: number;
  height?: number;
}) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  return createPortal(
    <div className={s.backdrop} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.dialog} style={{ width, height }} role="dialog" aria-label={title}>
        {title && (
          <div className={s.dialogHeader}>
            <div className={s.dialogTitle}>{title}</div>
            <IconButton icon="close" label="Close" onClick={onClose} />
          </div>
        )}
        <div className={s.dialogBody}>{children}</div>
        {footer && <div className={s.dialogFooter}>{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}

// ---------- Menú (contextual o desde un botón) ----------

export type MenuItem = { label: string; icon?: IconName; destructive?: boolean; onSelect: () => void } | "separator";

export function Menu({ x, y, items, onClose }: { x: number; y: number; items: MenuItem[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x, y });
  useLayoutEffect(() => {
    const r = ref.current?.getBoundingClientRect();
    if (r) setPos({ x: Math.min(x, window.innerWidth - r.width - 8), y: Math.min(y, window.innerHeight - r.height - 8) });
  }, [x, y]);
  useEffect(() => {
    const close = (e: Event) => {
      if (e instanceof KeyboardEvent && e.key !== "Escape") return;
      if (e instanceof MouseEvent && ref.current?.contains(e.target as Node)) return;
      onClose();
    };
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", close);
    window.addEventListener("blur", onClose);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", close);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);
  return createPortal(
    <div ref={ref} className={s.menu} style={{ left: pos.x, top: pos.y }} role="menu">
      {items.map((item, i) =>
        item === "separator" ? (
          <div key={i} className={s.menuSeparator} />
        ) : (
          <button
            key={i}
            type="button"
            role="menuitem"
            className={s.menuItem}
            data-destructive={item.destructive}
            onClick={() => {
              onClose();
              item.onSelect();
            }}
          >
            {item.icon && <Icon name={item.icon} size={14} />}
            {item.label}
          </button>
        ),
      )}
    </div>,
    document.body,
  );
}

/** Para abrir un Menu con clic derecho o desde un botón: `const menu = useMenu(); <div onContextMenu={menu.open}>…{menu.render(items)}`. */
export function useMenu() {
  const [at, setAt] = useState<{ x: number; y: number } | null>(null);
  return {
    open: (e: React.MouseEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
      setAt(e.type === "contextmenu" ? { x: e.clientX, y: e.clientY } : { x: r.left, y: r.bottom + 4 });
    },
    render: (items: MenuItem[]) => (at ? <Menu x={at.x} y={at.y} items={items} onClose={() => setAt(null)} /> : null),
  };
}
