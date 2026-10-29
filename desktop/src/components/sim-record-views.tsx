import { useEffect, useRef, useState } from "react";
import { Button, Dialog, Field, Icon, IconButton, Kbd, Select, TextInput } from "@/components/ui";
import { sessionRemaining, type RobotSession } from "@/types/lerobot-types";
import { Dev, type Device } from "@/types/hardware-types";
import { Units } from "@/utils/units";
import s from "./sim-record-views.module.css";

/** Antes de grabar en la simulación: qué tarea, cuántas demostraciones y con qué leader. Se abre como diálogo. */
export function SimRecordSheet({ leaders, onStart, onCancel }: {
  leaders: Device[];
  onStart: (leader: Device, task: string, episodes: number, seconds: number) => void;
  onCancel: () => void;
}) {
  const [task, setTask] = useState("");
  const [episodes, setEpisodes] = useState(20);
  const [seconds, setSeconds] = useState(30);
  const [leaderID, setLeaderID] = useState<string>(leaders[0]?.id ?? "");
  const disabled = task.trim() === "" || leaders.length === 0;

  const start = () => {
    const d = leaders.find((l) => l.id === leaderID) ?? leaders[0];
    if (d && !disabled) onStart(d, task.trim(), episodes, seconds);
  };

  return (
    <Dialog
      title="Record in the simulation"
      onClose={onCancel}
      width={480}
      footer={
        <>
          <Button onClick={onCancel}>Cancel</Button>
          <Button variant="primary" onClick={start} disabled={disabled}>
            Record
          </Button>
        </>
      }
    >
      <form
        className={s.form}
        onSubmit={(e) => {
          e.preventDefault();
          start();
        }}
      >
        <Field label="Task">
          <TextInput value={task} placeholder="Put the red cube in the box" onChange={(e) => setTask(e.target.value)} autoFocus />
        </Field>
        <Counter label="Demonstrations" value={episodes} min={1} max={200} step={5} onChange={setEpisodes} format={(v) => `${v} demonstrations`} />
        <Counter label="Length" value={seconds} min={5} max={300} step={5} onChange={setSeconds} format={(v) => `Up to ${Math.round(v)} s each`} />
        {leaders.length > 1 && (
          <Field label="Leader">
            <Select value={leaderID} options={leaders.map((d) => ({ value: d.id, label: Dev.displayName(d) }))} onChange={setLeaderID} />
          </Field>
        )}
        <div className={s.keys}>
          <Kbd>→</Kbd> done <Kbd>←</Kbd> redo <Kbd>Esc</Kbd> save
        </div>
      </form>
    </Dialog>
  );
}

function Counter({ label, value, min, max, step, onChange, format }: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
  format: (v: number) => string;
}) {
  return (
    <div className={s.counter}>
      <span className={s.counterLabel}>{label}</span>
      <span className={s.counterValue}>{format(value)}</span>
      <IconButton icon="minus" label="Less" size={13} disabled={value <= min} onClick={() => onChange(Math.max(min, value - step))} />
      <IconButton icon="add" label="More" size={13} disabled={value >= max} onClick={() => onChange(Math.min(max, value + step))} />
    </div>
  );
}

/** Mientras graba en la simulación: en qué va, el tiempo y los tres botones con su tecla (←, →, Esc). */
export function SimRecordBar({ session, onNext, onRedo, onStop }: {
  session: RobotSession;
  onNext: () => void;
  onRedo: () => void;
  onStop: () => void;
}) {
  const phase = session.phase;
  const recording = phase === "recording";
  const canNext = recording || phase === "reset";

  const keys = useRef({ onNext, onRedo, onStop, recording, canNext });
  keys.current = { onNext, onRedo, onStop, recording, canNext };
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName))) return;
      const k = keys.current;
      if (e.key === "ArrowLeft" && k.recording) k.onRedo();
      else if (e.key === "ArrowRight" && k.canNext) k.onNext();
      else if (e.key === "Escape") k.onStop();
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const title =
    phase === "starting" ? "Connecting the leader…"
    : recording ? `Demonstration ${session.episode + 1} of ${session.target}`
    : phase === "reset" ? "Reset the scene"
    : phase === "saving" ? "Saving…"
    : "";

  return (
    <div className={s.bar}>
      <span className={s.state} data-recording={recording}>
        {recording ? <span className={s.recDot} /> : <Icon name="pause" size={15} />}
      </span>
      <div className={s.text}>
        <div className={s.title}>{title}</div>
        {session.limit > 0 && <div className={s.clock}>{Units.clock(sessionRemaining(session))}</div>}
      </div>
      <span className={s.divider} />
      <Button size="small" onClick={onRedo} disabled={!recording} title="←">
        Redo
      </Button>
      <Button size="small" variant="primary" onClick={onNext} disabled={!canNext} title="→">
        {phase === "reset" ? "Next" : "Done"}
      </Button>
      <Button size="small" variant="ghost" onClick={onStop} title="Esc">
        Save
      </Button>
    </div>
  );
}
