import { Badge, Button, Callout, Divider, IconButton, Progress, Spinner, SwitchRow, TextArea, TextInput, useMenu, type MenuItem } from "@/components/ui";
import type { SkillModel, SkillResult, SkillRun } from "@/types/lerobot-types";
import s from "./skill-panel.module.css";

function reasonText(r: string): string {
  switch (r) {
    case "time": return "time's up";
    case "stopped": return "stopped";
    case "interrupted": return "cut off by the controls";
    default: return r;
  }
}

/**
 * El modelo de órdenes del robot (SmolVLA, π0…): cargarlo en la sesión en vivo, probarlo a mano con una
 * orden en palabras y dejar que la IA del chat lo use para planear. Solo dibuja: todo por props.
 */
export function SkillPanel(props: {
  trained: { name: string; path: string }[];
  path: string;
  onPathChange: (path: string) => void;
  loaded: SkillModel | null;
  loading: boolean;
  error: string | null;
  forAI: boolean;
  onForAIChange: (on: boolean) => void;
  instruction: string;
  onInstructionChange: (text: string) => void;
  seconds: number;
  onSecondsChange: (seconds: number) => void;
  running: SkillRun | null;
  last: SkillResult | null;
  recent: string[];
  disabled?: boolean;
  onLoad: () => void;
  onRun: () => void;
  onStop: () => void;
}) {
  const { loaded, disabled } = props;
  return (
    <div className={s.panel}>
      <span className={s.heading}>Action model</span>
      <Model {...props} />
      {loaded != null && (
        <>
          <Divider />
          <TryIt {...props} />
          <Divider />
          <SwitchRow title="The chat AI can use it" on={props.forAI} onChange={props.onForAIChange} disabled={disabled} />
        </>
      )}
    </div>
  );
}

function Model({ trained, path, onPathChange, loaded, loading, error, running, disabled, onLoad }: Parameters<typeof SkillPanel>[0]) {
  const menu = useMenu();
  const items: MenuItem[] = [
    ...(trained.length === 0 ? [{ label: "No trained models yet", onSelect: () => {} }] : trained.map((m) => ({ label: m.name, icon: "model" as const, onSelect: () => onPathChange(m.path) }))),
    "separator",
    { label: "lerobot/smolvla_base (not fine-tuned)", icon: "globe", onSelect: () => onPathChange("lerobot/smolvla_base") },
  ];
  return (
    <div className={s.group}>
      <div className={s.row}>
        <TextInput
          className={s.grow}
          placeholder="Folder or Hub id (lerobot/smolvla_base)"
          value={path}
          disabled={disabled}
          onChange={(e) => onPathChange(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && onLoad()}
        />
        <IconButton icon="list" label="Pick a model" disabled={disabled} onClick={menu.open} />
        {menu.render(items)}
      </div>
      <div className={s.row}>
        <Button variant="primary" size="small" disabled={disabled || loading || !path || loaded?.path === path || running != null} onClick={onLoad}>
          {loaded?.path === path ? "Loaded" : "Load"}
        </Button>
        {loading ? (
          <span className={s.caption}>
            <Spinner size={12} /> Loading…
          </span>
        ) : (
          loaded && (
            <Badge tone="green" icon="checkCircle">
              {loaded.type} · {loaded.device}
            </Badge>
          )
        )}
      </div>
      {loaded?.note && <Callout tone="amber">{loaded.note}</Callout>}
      {error && <Callout tone="red">{error}</Callout>}
    </div>
  );
}

function TryIt({ instruction, onInstructionChange, seconds, onSecondsChange, running, last, recent, disabled, onRun, onStop }: Parameters<typeof SkillPanel>[0]) {
  return (
    <div className={s.group}>
      <span className={s.heading}>Try it</span>
      <TextArea
        rows={2}
        placeholder="pick up the cube and put it in the box"
        value={instruction}
        disabled={disabled}
        onChange={(e) => onInstructionChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            if (running == null) onRun();
          }
        }}
      />
      {recent.length > 0 && (
        <div className={s.chips}>
          {recent.map((item) => (
            <button key={item} type="button" className={s.chip} disabled={disabled} onClick={() => onInstructionChange(item)}>
              {item}
            </button>
          ))}
        </div>
      )}
      <div className={s.row}>
        <div className={s.stepper}>
          <span>
            Up to <span className={s.num}>{Math.trunc(seconds)}</span> s
          </span>
          <IconButton icon="minus" label="Less time" size={13} disabled={disabled || seconds <= 3} onClick={() => onSecondsChange(Math.max(3, seconds - 1))} />
          <IconButton icon="add" label="More time" size={13} disabled={disabled || seconds >= 60} onClick={() => onSecondsChange(Math.min(60, seconds + 1))} />
        </div>
        <span className={s.grow} />
        {running != null ? (
          <Button variant="danger" size="small" icon="stop" disabled={disabled} onClick={onStop}>
            Stop
          </Button>
        ) : (
          <Button variant="primary" size="small" icon="play" disabled={disabled || !instruction.trim()} onClick={onRun}>
            Run
          </Button>
        )}
      </div>
      {running != null ? (
        <div className={s.group}>
          <Progress value={Math.min(running.elapsed, running.limit) / Math.max(running.limit, 1)} />
          <span className={s.caption}>
            «{running.instruction}» · <span className={s.num}>{Math.trunc(running.elapsed)}</span> of <span className={s.num}>{Math.trunc(running.limit)}</span> s
          </span>
        </div>
      ) : (
        last && (
          <span className={s.caption} data-error={last.reason.startsWith("error")}>
            «{last.instruction}» · {reasonText(last.reason)} after <span className={s.num}>{last.seconds.toFixed(1)}</span> s
          </span>
        )
      )}
    </div>
  );
}
