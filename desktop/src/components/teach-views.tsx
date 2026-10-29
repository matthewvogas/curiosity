import { useEffect, useRef, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Button, Dialog, Icon, IconButton, Kbd, Spinner, TextInput, useMenu, cx } from "@/components/ui";
import { TileLayout, Tile } from "@/components/tile-layout";
import { SimStage } from "@/components/sim-stage";
import type { SimulationQueries } from "@/queries/simulation-queries";
import { HubQueries } from "@/queries/hub-queries";
import { sessionRemaining, type HubDataset, type RobotSession } from "@/types/lerobot-types";
import { Units } from "@/utils/units";
import { jpegDataURL } from "@/utils/codable";
import s from "./teach-views.module.css";

// Enseñarle una tarea al robot real, en tres pasos guiados. Solo dibujan: datos y acciones por props.

/** Las teclas de una pantalla (flechas y Esc), sin robarlas a un campo de texto. */
function useKeys(map: Record<string, (() => void) | undefined>) {
  const ref = useRef(map);
  ref.current = map;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName))) return;
      const f = ref.current[e.key];
      if (f) {
        e.preventDefault();
        f();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}

const EXAMPLES = ["Put the red cube in the cup", "Stack the two blocks", "Push the ball to the left"];

/** Sin tareas: una sola pregunta, centrada, con un campo tipo composer. */
export function TaskEmptyState({ onCreate, onCancel }: { onCreate: (title: string) => void; onCancel?: () => void }) {
  const [title, setTitle] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const empty = title.trim() === "";

  useEffect(() => input.current?.focus(), []);

  const create = () => {
    const t = title.trim();
    if (t) onCreate(t);
  };

  return (
    <div className={s.emptyWrap}>
      {onCancel && (
        <div className={s.emptyCancel}>
          <Button variant="ghost" onClick={onCancel}>
            Cancel
          </Button>
        </div>
      )}
      <div className={s.emptyIcon}>
        <Icon name="hand" size={22} />
      </div>
      <h1 className={s.emptyTitle}>What do you want it to learn?</h1>
      <form
        className={s.composer}
        onSubmit={(e) => {
          e.preventDefault();
          create();
        }}
      >
        <input
          ref={input}
          className={s.composerInput}
          value={title}
          placeholder="Describe the task in one sentence"
          spellCheck={false}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => e.key === "Escape" && onCancel?.()}
        />
        <button type="submit" className={s.send} disabled={empty} title="Start (↩)" aria-label="Start">
          <Icon name="send" size={15} strokeWidth={2.25} />
        </button>
      </form>
      <div className={s.ideas}>
        <span className={s.ideasLabel}>Ideas</span>
        <div className={s.chips}>
          {EXAMPLES.map((e) => (
            <button
              key={e}
              type="button"
              className={s.chip}
              onClick={() => {
                setTitle(e);
                input.current?.focus();
              }}
            >
              {e}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

/**
 * Grabando, como una app de grabación: la cámara manda; encima, el estado (● REC y el tiempo, o «Reset») y
 * cuál demostración es; debajo, el avance y una sola barra de controles con su tecla.
 */
export function RecordingView({ session, frame, onNext, onRedo, onStop }: {
  session: RobotSession;
  frame: string | null;
  onNext: () => void;
  onRedo: () => void;
  onStop: () => void;
}) {
  const phase = session.phase;
  const canNext = phase === "recording" || phase === "reset";
  const busy = phase === "starting" || phase === "saving";
  useKeys({
    ArrowLeft: phase === "recording" ? onRedo : undefined,
    ArrowRight: canNext ? onNext : undefined,
    Escape: busy ? undefined : onStop,
  });

  const time = session.limit > 0 ? Units.clock(sessionRemaining(session)) : null;
  const total = Math.max(session.target, 1);
  const done = Math.min(session.episode, total);

  return (
    <div className={s.center}>
      <div className={s.recording}>
        <div className={s.feed}>
          <div className={s.stage}>
            <LivePicture frame={frame} />
            {canNext && (
              <div className={s.overlayTop}>
                <span className={cx(s.pill, phase === "recording" && s.pillRec)}>
                  {phase === "recording" ? <span className={s.recDot} /> : <Icon name="reset" size={12} />}
                  {phase === "recording" ? "REC" : "Reset the scene"}
                  {time && <span className={s.pillTime}>{time}</span>}
                </span>
                <span className={s.pill}>
                  Demo {Math.min(done + 1, total)} <span className={s.pillDim}>/ {session.target}</span>
                </span>
              </div>
            )}
            {busy && (
              <div className={s.overlayCenter}>
                <Spinner size={16} />
                {phase === "starting" ? "Connecting the arms and camera…" : "Saving the demonstrations…"}
              </div>
            )}
          </div>
          <div className={s.progress} aria-label={`${done} of ${session.target} recorded`}>
            {Array.from({ length: total }, (_, i) => (
              <span key={i} className={s.progressStep} data-state={i < done ? "done" : i === done && phase === "recording" ? "now" : "todo"} />
            ))}
          </div>
        </div>

        <div className={s.controls}>
          <button type="button" className={s.control} onClick={onRedo} disabled={phase !== "recording"} title="Redo this demonstration (←)">
            <Icon name="reset" size={15} />
            Redo
            <Kbd>←</Kbd>
          </button>
          <button
            type="button"
            className={cx(s.control, s.controlMain)}
            onClick={onNext}
            disabled={!canNext}
            title={phase === "reset" ? "Start the next one (→)" : "Finish this one (→)"}
          >
            {phase === "reset" ? "Start next" : "Next"}
            <Kbd>→</Kbd>
          </button>
          <button type="button" className={cx(s.control, s.controlStop)} onClick={onStop} disabled={busy} title="Stop and save (Esc)">
            <Icon name="stop" size={13} fill />
            Stop
            <Kbd>Esc</Kbd>
          </button>
        </div>
      </div>
    </div>
  );
}

/**
 * El robot usa el modelo: sus cámaras y el modelo 3D (como en vivo, cada uno se puede ocultar) y un solo
 * botón para detenerlo. Los paneles ocultos llegan por props (la pantalla los recuerda).
 */
export function RunningView({ session, frames, twin, hidden, onHiddenChange, onStop }: {
  session: RobotSession;
  frames: Record<string, string>;
  twin: SimulationQueries;
  /** Los paneles ocultos, por nombre («3D» es el modelo). */
  hidden: string[];
  onHiddenChange: (hidden: string[]) => void;
  onStop: () => void;
}) {
  const [focused, setFocused] = useState(0);
  const menu = useMenu();
  useKeys({ Escape: onStop });

  const panels = [...(session.cameras.length === 0 ? Object.keys(frames).sort() : session.cameras), "3D"];
  const shown = panels.filter((p) => !hidden.includes(p));
  const main = Math.min(focused, shown.length - 1);
  const label = (key: string) => (key === "3D" ? "3D model" : key);

  const toggle = (key: string) => {
    const next = hidden.includes(key) ? hidden.filter((h) => h !== key) : [...hidden, key];
    onHiddenChange(next.sort());
    setFocused(0);
  };

  const status =
    session.phase === "running" ? `The robot is doing the task · ${Units.clock(session.elapsed)} of ${Units.clock(session.limit)}`
    : session.phase === "returning" ? "Returning to the home pose…"
    : "Loading the model and connecting…";

  return (
    <div className={s.running}>
      <div className={s.tiles}>
        {shown.length === 0 ? (
          <div className={s.allHidden}>All panels hidden</div>
        ) : (
          <TileLayout focused={main}>
            {shown.map((key, i) => (
              <Tile key={key} title={label(key)} focused={i === main} onTap={() => setFocused(i)}>
                {key === "3D" ? (
                  <SimStage engine={twin} />
                ) : frames[key] ? (
                  <img className={s.frame} src={jpegDataURL(frames[key])} alt={key} />
                ) : (
                  <div className={s.frameWait}>
                    <Spinner />
                  </div>
                )}
              </Tile>
            ))}
          </TileLayout>
        )}
      </div>
      <div className={s.runStatus}>{status}</div>
      <div className={s.runActions}>
        <Button icon="panels" onClick={menu.open} title="Show or hide panels">
          Show
        </Button>
        {menu.render(
          panels.map((key) => ({
            label: label(key),
            icon: hidden.includes(key) ? undefined : ("check" as const),
            onSelect: () => toggle(key),
          })),
        )}
        <Button size="large" variant="danger" icon="stop" onClick={onStop} title="Esc">
          Stop robot <Kbd>Esc</Kbd>
        </Button>
      </div>
    </div>
  );
}

/** Buscar un dataset en Hugging Face y usarlo en lugar de grabar. Se abre como diálogo. */
export function HubPickerView({ results, query, onQueryChange, searching, onSearch, onPick, onClose, detail = "" }: {
  results: HubDataset[];
  query: string;
  onQueryChange: (q: string) => void;
  searching: boolean;
  onSearch: () => void;
  onPick: (d: HubDataset) => void;
  onClose: () => void;
  detail?: string;
}) {
  return (
    <Dialog title="Data from Hugging Face" onClose={onClose} width={560} height={520} footer={<Button onClick={onClose}>Close</Button>}>
      <div className={s.hub}>
        {detail && <p className={s.muted}>{detail}</p>}
        <form
          className={s.hubSearch}
          onSubmit={(e) => {
            e.preventDefault();
            onSearch();
          }}
        >
          <TextInput value={query} placeholder="Search" onChange={(e) => onQueryChange(e.target.value)} autoFocus />
          <Button type="submit" disabled={searching} icon={searching ? "spinner" : "search"}>
            {searching ? "Searching…" : "Search"}
          </Button>
        </form>
        <div className={s.hubList}>
          {results.length === 0 && !searching && <div className={cx(s.muted, s.hubEmpty)}>No results yet.</div>}
          {results.map((d) => (
            <div key={d.id} className={s.hubRow}>
              <div className={s.hubText}>
                <div className={s.ellipsis}>{d.id}</div>
                <div className={s.small}>{d.downloads.toLocaleString()} downloads</div>
              </div>
              <IconButton icon="external" label="View on Hugging Face" size={14} onClick={() => void openUrl(HubQueries.url(d.id))} />
              <Button size="small" onClick={() => onPick(d)}>
                Use
              </Button>
            </div>
          ))}
        </div>
      </div>
    </Dialog>
  );
}

/** La cámara del robot en vivo (JPEG en base64). */
export function LivePicture({ frame }: { frame: string | null }) {
  return frame ? (
    <img className={s.picture} src={jpegDataURL(frame)} alt="Camera" />
  ) : (
    <div className={cx(s.picture, s.pictureWait)}>
      <Spinner size={18} />
    </div>
  );
}
