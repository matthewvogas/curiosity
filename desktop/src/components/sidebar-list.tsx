import { useState, type ReactNode } from "react";
import type { Robot } from "@/types/robot-types";
import type { Device } from "@/types/hardware-types";
import { Dev } from "@/types/hardware-types";
import type { TaskPhase } from "@/utils/task-status";
import { Icon, IconButton, Logo, useMenu, type IconName } from "./ui";
import s from "./sidebar-list.module.css";

/** Una tarea, tal como se lista bajo su robot. */
export type SidebarTask = { id: string; title: string; summary: string; phase: TaskPhase };

export type SidebarPage = "home" | "library";

/**
 * Barra lateral: mis robots para simular y mis robots físicos (con sus tareas debajo, como archivos de un
 * proyecto). Cada sección tiene su +. La fila elegida apenas se marca, con una línea verde a la izquierda.
 */
export function SidebarList(p: {
  page: SidebarPage | null;
  robots: Robot[];
  selectedID: string | null;
  devices: Device[];
  connectedPorts: string[];
  selectedDeviceID: string | null;
  tasks: Record<string, SidebarTask[]>;
  selectedTaskID: string | null;
  onPage: (page: SidebarPage) => void;
  onSelect: (r: Robot) => void;
  onSelectDevice: (d: Device) => void;
  onAdd: () => void;
  onConnect: () => void;
  onRemove: (r: Robot) => void;
  onRemoveDevice: (d: Device) => void;
  onReveal: (r: Robot) => void;
  onSelectTask: (d: Device, id: string) => void;
  onNewTask: (d: Device) => void;
  onRemoveTask: (id: string) => void;
  onSettings: () => void;
}) {
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggle = (key: string) =>
    setCollapsed((c) => {
      const n = new Set(c);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });

  return (
    <>
      <div className={s.list}>
        {/* El logo va en la misma columna que los íconos de las filas, un poco más grande (es la marca). */}
        <div className={s.brand}>
          <span className={s.rowIcon}>
            <Logo size={20} />
          </span>
          Curiosity
        </div>
        <nav className={s.nav}>
          <Row icon="home" title="Home" selected={p.page === "home"} onClick={() => p.onPage("home")} />
          <Row icon="library" title="Robot library" selected={p.page === "library"} onClick={() => p.onPage("library")} />
        </nav>

        <Header title="Simulation" help="Open simulator" collapsed={collapsed.has("sim")} onToggle={() => toggle("sim")} onAdd={p.onAdd} />
        {!collapsed.has("sim") &&
          (p.robots.length === 0 ? (
            <div className={s.hint}>No robots yet</div>
          ) : (
            p.robots.map((r) => (
              <Row
                key={r.id}
                icon="robot"
                title={r.name}
                meta={origin(r)}
                selected={r.id === p.selectedID}
                onClick={() => p.onSelect(r)}
                menu={[
                  { label: "Show in folder", icon: "folder", onSelect: () => p.onReveal(r) },
                  "separator",
                  { label: "Remove from list", icon: "trash", destructive: true, onSelect: () => p.onRemove(r) },
                ]}
              />
            ))
          ))}

        <Header title="Connected robots" help="Connect external robot" collapsed={collapsed.has("devices")} onToggle={() => toggle("devices")} onAdd={p.onConnect} />
        {!collapsed.has("devices") &&
          (p.devices.length === 0 ? (
            <div className={s.hint}>Plug in a robot over USB</div>
          ) : (
            p.devices.map((d) => {
              const plugged = p.connectedPorts.includes(d.id);
              const open = !collapsed.has(d.id);
              return (
                <div key={d.id}>
                  <Row
                    icon="link"
                    title={Dev.displayName(d)}
                    meta={!plugged ? "Unplugged" : d.leaderPort ? "With leader" : "Plugged in"}
                    selected={d.id === p.selectedDeviceID && p.selectedTaskID == null}
                    onClick={() => p.onSelectDevice(d)}
                    trailing={
                      <span
                        role="button"
                        className={s.disclose}
                        data-open={open}
                        title={open ? "Hide tasks" : "Show tasks"}
                        onClick={(e) => {
                          e.stopPropagation();
                          toggle(d.id);
                        }}
                      >
                        <Icon name="chevron" size={12} />
                      </span>
                    }
                    menu={[
                      { label: "New task…", icon: "add", onSelect: () => p.onNewTask(d) },
                      "separator",
                      { label: "Remove from list", icon: "trash", destructive: true, onSelect: () => p.onRemoveDevice(d) },
                    ]}
                  />
                  {open && (
                    <div className={s.nested}>
                      {(p.tasks[d.id] ?? []).map((t) => (
                        <Row
                          key={t.id}
                          compact
                          icon={phaseIcon(t.phase)}
                          title={t.title}
                          meta={t.summary}
                          selected={t.id === p.selectedTaskID}
                          onClick={() => p.onSelectTask(d, t.id)}
                          menu={[{ label: "Remove task", icon: "trash", destructive: true, onSelect: () => p.onRemoveTask(t.id) }]}
                        />
                      ))}
                      <Row compact muted icon="add" title="New task" onClick={() => p.onNewTask(d)} />
                    </div>
                  )}
                </div>
              );
            })
          ))}
      </div>
      <div className={s.footer}>
        <span className={s.footerStatus} />
        <IconButton icon="settings" label="Settings" onClick={p.onSettings} />
      </div>
    </>
  );
}

function Header({ title, help, collapsed, onToggle, onAdd }: { title: string; help: string; collapsed: boolean; onToggle: () => void; onAdd?: () => void }) {
  return (
    <div className={s.header}>
      <button type="button" className={s.headerToggle} onClick={onToggle} title={collapsed ? "Show" : "Hide"}>
        {title}
        <span className={s.headerChevron} data-collapsed={collapsed} style={{ transform: collapsed ? undefined : "rotate(90deg)" }}>
          <Icon name="chevron" size={11} />
        </span>
      </button>
      {onAdd && <IconButton icon="add" label={help} size={14} onClick={onAdd} />}
    </div>
  );
}

function Row({ icon, iconNode, title, meta, selected, compact, muted, trailing, onClick, menu }: {
  icon?: IconName;
  iconNode?: ReactNode;
  title: string;
  meta?: string;
  selected?: boolean;
  compact?: boolean;
  muted?: boolean;
  trailing?: ReactNode;
  onClick: () => void;
  menu?: Parameters<ReturnType<typeof useMenu>["render"]>[0];
}) {
  const m = useMenu();
  return (
    <>
      <button type="button" className={s.row} data-selected={!!selected} data-compact={!!compact} data-muted={!!muted} onClick={onClick} onContextMenu={menu ? m.open : undefined}>
        <span className={s.rowIcon}>{iconNode ?? (icon && <Icon name={icon} size={compact ? 13 : 15} />)}</span>
        <span className={s.rowText}>
          <span className={s.rowTitle}>{title}</span>
        </span>
        {meta && <span className={s.rowMeta}>{meta}</span>}
        {trailing}
      </button>
      {menu && m.render(menu)}
    </>
  );
}

function phaseIcon(phase: TaskPhase): IconName {
  return phase === "training" ? "taskTraining" : phase === "learned" ? "taskLearned" : "task";
}

function origin(r: Robot): string {
  return r.source === "bundled" ? "Default" : r.source === "library" ? r.summary : "Imported";
}
