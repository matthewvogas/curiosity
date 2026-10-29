// Para la app de escritorio (Tauri): el visor vive en un iframe de otro origen, así que la app llama a
// window.studio.* por postMessage ({ rpc, fn, args }) y recibe { rpc, ok, value | error }.
// En la app de macOS no hace nada: ahí se llama a window.studio directamente.
window.addEventListener("message", async (e) => {
  const { rpc, fn, args = [] } = e.data || {};
  if (rpc === undefined || typeof fn !== "string") return;
  try {
    if (!window.studio || typeof window.studio[fn] !== "function") throw new Error(`studio.${fn} doesn't exist`);
    const value = await window.studio[fn](...args);
    e.source.postMessage({ rpc, ok: true, value }, "*");
  } catch (err) {
    e.source.postMessage({ rpc, ok: false, error: String(err?.message || err) }, "*");
  }
});
