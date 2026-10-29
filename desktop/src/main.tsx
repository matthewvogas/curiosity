import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { configure } from "mobx";
import "@/styles/base.css";
import { loadNativePaths } from "@/queries/native";
import { createStores, StoresProvider } from "@/app/stores";
import { RootScreen } from "@/screens/root-screen";
import { invoke } from "@tauri-apps/api/core";

// En desarrollo, la consola de la página también sale en la terminal de `tauri dev`.
if (import.meta.env.DEV) {
  for (const level of ["log", "warn", "error"] as const) {
    const original = console[level].bind(console);
    console[level] = (...args: unknown[]) => {
      original(...args);
      const text = args.map((a) => (a instanceof Error ? `${a.message}\n${a.stack}` : typeof a === "string" ? a : JSON.stringify(a))).join(" ");
      void invoke("log_line", { level, text }).catch(() => {});
    };
  }
}

// Los stores cambian su estado desde sus propios métodos; MobX no exige envolver cada cambio.
configure({ enforceActions: "never" });

async function start() {
  await loadNativePaths();
  const stores = createStores();
  await Promise.all([stores.robots.load(), stores.tasks.load(), stores.library.load(), stores.devices.load()]);
  // Las keys y la búsqueda de LeRobot pueden tardar: la ventana no las espera.
  void stores.settings.load();
  createRoot(document.getElementById("root")!).render(
    <StrictMode>
      <StoresProvider stores={stores}>
        <RootScreen />
      </StoresProvider>
    </StrictMode>,
  );
}

// Si algo falla al arrancar, que se vea (en vez de una ventana vacía).
function showFatal(e: unknown) {
  console.error("fatal", e);
  const root = document.getElementById("root")!;
  root.innerHTML = "";
  const pre = document.createElement("pre");
  pre.style.cssText = "padding:60px 24px;color:#f0616d;white-space:pre-wrap;font:12px ui-monospace,monospace";
  pre.textContent = `Curiosity couldn't start:\n\n${e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e)}`;
  root.append(pre);
}
window.addEventListener("error", (e) => showFatal(e.error ?? e.message));
window.addEventListener("unhandledrejection", (e) => showFatal(e.reason));
start().catch(showFatal);
