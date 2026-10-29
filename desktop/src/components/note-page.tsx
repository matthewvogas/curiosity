import { useEffect, useRef } from "react";
import { IconButton, Spinner, type IconName } from "@/components/ui";
import s from "./note-page.module.css";

/**
 * La página de notas de una tarea, como un documento: una tarjeta como las de la página de pasos, con una barra
 * pequeña (título, negrita, cursiva, lista). Se guarda sola: cada cambio llama a `onSave` (con una pausa corta)
 * y lo pendiente se guarda al cerrarla. Solo dibuja: el HTML llega por props; para otra tarea, otra `key`.
 */
export function NotePage({ html, onSave, delay = 500 }: {
  /** El documento guardado; null mientras se lee. */
  html: string | null;
  onSave: (html: string) => void;
  delay?: number;
}) {
  const editor = useRef<HTMLDivElement>(null);
  const loaded = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const dirty = useRef(false);
  const save = useRef(onSave);
  save.current = onSave;

  // El contenido se pone una sola vez: después manda lo que se escribe (si no, el cursor saltaría).
  useEffect(() => {
    if (html == null || loaded.current || !editor.current) return;
    editor.current.innerHTML = html;
    loaded.current = true;
  }, [html]);

  const flush = () => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;
    if (dirty.current && editor.current) {
      dirty.current = false;
      save.current(editor.current.innerHTML);
    }
  };

  useEffect(() => flush, []);

  const changed = () => {
    dirty.current = true;
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(flush, delay);
  };

  const run = (command: string, value?: string) => {
    editor.current?.focus();
    document.execCommand(command, false, value);
    changed();
  };

  const toggleHeading = () => {
    const block = String(document.queryCommandValue("formatBlock") || "").toLowerCase();
    run("formatBlock", block === "h2" ? "<p>" : "<h2>");
  };

  const tools: { name: string; icon: IconName; keys: string; action: () => void }[] = [
    { name: "Heading", icon: "heading", keys: "⇧⌘H", action: toggleHeading },
    { name: "Bold", icon: "bold", keys: "⌘B", action: () => run("bold") },
    { name: "Italic", icon: "italic", keys: "⌘I", action: () => run("italic") },
    { name: "List", icon: "list", keys: "⇧⌘L", action: () => run("insertUnorderedList") },
  ];

  const onKeyDown = (e: React.KeyboardEvent) => {
    const mod = e.metaKey || e.ctrlKey;
    if (!mod || !e.shiftKey) return;
    const k = e.key.toLowerCase();
    if (k === "h") {
      e.preventDefault();
      toggleHeading();
    } else if (k === "l") {
      e.preventDefault();
      run("insertUnorderedList");
    }
  };

  return (
    <div className={s.wrap}>
      <div className={s.card}>
        <div className={s.toolbar}>
          {tools.map((t) => (
            <IconButton
              key={t.name}
              icon={t.icon}
              label={`${t.name} (${t.keys})`}
              size={14}
              onMouseDown={(e) => e.preventDefault()}
              onClick={t.action}
              disabled={html == null}
            />
          ))}
        </div>
        {html == null && (
          <div className={s.loading}>
            <Spinner />
          </div>
        )}
        <div
          ref={editor}
          className={s.editor}
          hidden={html == null}
          contentEditable
          suppressContentEditableWarning
          spellCheck
          data-placeholder="Notes about this task: what worked, the setup, ideas…"
          onInput={changed}
          onKeyDown={onKeyDown}
          onBlur={flush}
        />
      </div>
    </div>
  );
}
