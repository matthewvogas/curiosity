import type { ReactNode } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { nativePaths } from "@/queries/native";
import { Icon, cx } from "./ui";
import s from "./app-shell.module.css";

/**
 * El marco de la ventana: barra lateral a la izquierda y el área de trabajo a la derecha. Cada pantalla
 * pone su encabezado (que también es la barra de título: se arrastra la ventana desde ahí) y, si quiere,
 * un inspector a la derecha con su propio encabezado.
 */
export function AppShell({ sidebar, sidebarVisible, children }: { sidebar: ReactNode; sidebarVisible: boolean; children: ReactNode }) {
  const platform = nativePaths().platform;
  return (
    <div className={s.shell} data-sidebar={sidebarVisible} data-platform={platform}>
      <aside className={s.sidebar}>{sidebar}</aside>
      {children}
      {platform !== "macos" && <CaptionButtons />}
    </div>
  );
}

/** La parte de arriba de la barra lateral (deja lugar a los semáforos en macOS). */
export function SidebarTop({ children }: { children?: ReactNode }) {
  return (
    <div className={s.sidebarTop} data-platform={nativePaths().platform} data-tauri-drag-region>
      {children}
    </div>
  );
}

/** Área de trabajo: un panel principal y, opcional, el inspector a la derecha. */
export function Workspace({ children, inspector }: { children: ReactNode; inspector?: ReactNode }) {
  return (
    <main className={s.main} data-inspector={!!inspector}>
      {children}
      {inspector}
    </main>
  );
}

/**
 * Un panel con encabezado (barra de título) y contenido. El que queda arriba a la derecha (el inspector,
 * o el panel principal si no hay inspector) lleva `captionSafe` para dejar lugar a los botones de Windows.
 */
export function Pane({ title, leading, center, actions, children, inspector, captionSafe, bodyClassName }: {
  title?: ReactNode;
  leading?: ReactNode;
  center?: ReactNode;
  actions?: ReactNode;
  children: ReactNode;
  /** El inspector usa otro fondo. */
  inspector?: boolean;
  captionSafe?: boolean;
  bodyClassName?: string;
}) {
  const safe = (captionSafe ?? inspector) && nativePaths().platform !== "macos";
  return (
    <section className={inspector ? s.inspector : s.pane}>
      <header className={cx(s.header, safe && s.captionSafe)} data-tauri-drag-region>
        {leading}
        {title && <div className={s.headerTitle}>{title}</div>}
        {inspector && center && <div className={s.inspectorCenter}>{center}</div>}
        <div className={s.headerSpacer} data-tauri-drag-region />
        {!inspector && center && <div className={s.headerCenter}>{center}</div>}
        {actions && <div className={s.headerActions}>{actions}</div>}
      </header>
      <div className={cx(s.body, bodyClassName)}>{children}</div>
    </section>
  );
}

function CaptionButtons() {
  const w = getCurrentWindow();
  return (
    <div className={s.caption}>
      <button type="button" className={s.captionButton} aria-label="Minimize" onClick={() => w.minimize()}>
        <Icon name="minus" size={15} strokeWidth={1.5} />
      </button>
      <button type="button" className={s.captionButton} aria-label="Maximize" onClick={() => w.toggleMaximize()}>
        <svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" strokeWidth="1.1"><rect x="0.5" y="0.5" width="10" height="10" rx="1.5" /></svg>
      </button>
      <button type="button" className={cx(s.captionButton, s.captionClose)} aria-label="Close" onClick={() => w.close()}>
        <Icon name="close" size={16} strokeWidth={1.5} />
      </button>
    </div>
  );
}
