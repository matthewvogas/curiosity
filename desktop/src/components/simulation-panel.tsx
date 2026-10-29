import type { ReactNode } from "react";
import { Button, Icon, IconButton, Select, Slider, Switch } from "@/components/ui";
import { actuatedJoints, type Keyframe, type PhysicsSettings, type RenderOptions, type RobotModel, type SimulationState } from "@/types/robot-types";
import { swiftDate } from "@/utils/codable";
import s from "./simulation-panel.module.css";

const SPEEDS = [0.1, 0.25, 0.5, 1, 2, 4];
const TIMESTEPS = [
  { value: 1 / 1000, label: "1 ms" },
  { value: 1 / 500, label: "2 ms" },
  { value: 1 / 250, label: "4 ms" },
  { value: 1 / 125, label: "8 ms" },
];

/**
 * Las opciones de la simulación, como el panel izquierdo de MuJoCo (`simulate`), en secciones plegables:
 * Simulación, Física, Visualización, Info, Sensores y Archivo.
 */
export function SimulationPanel(p: {
  state: SimulationState;
  model: RobotModel | null;
  physics: PhysicsSettings;
  onPhysics: (physics: PhysicsSettings) => void;
  render: RenderOptions;
  onRender: (render: RenderOptions) => void;
  keyframes: Keyframe[];
  speed: number;
  /** Las secciones plegadas (se recuerdan en la pantalla). */
  closed: string[];
  onClosed: (closed: string[]) => void;
  onTogglePause: () => void;
  onReset: () => void;
  onReload: () => void;
  onAlign: () => void;
  onCopyState: () => void;
  onSpeed: (x: number) => void;
  onSaveKey: () => void;
  onLoadKey: (key: Keyframe) => void;
  onDeleteKey: (key: Keyframe) => void;
  onScreenshot: () => void;
  onShowModel: () => void;
}) {
  const { state, model, physics, render } = p;
  const setPhysics = <K extends keyof PhysicsSettings>(k: K, v: PhysicsSettings[K]) => p.onPhysics({ ...physics, [k]: v });
  const setRender = <K extends keyof RenderOptions>(k: K, v: RenderOptions[K]) => p.onRender({ ...render, [k]: v });

  const section = (title: string, children: ReactNode) => {
    const open = !p.closed.includes(title);
    return (
      <div className={s.section} key={title}>
        <button
          type="button"
          className={s.sectionHead}
          aria-expanded={open}
          onClick={() => p.onClosed(open ? [...p.closed, title].sort() : p.closed.filter((c) => c !== title))}
        >
          <Icon name={open ? "chevronDown" : "chevron"} size={13} />
          {title}
        </button>
        {open && <div className={s.sectionBody}>{children}</div>}
      </div>
    );
  };

  return (
    <div className={s.panel}>
      {section(
        "Simulation",
        <>
          <div className={s.buttons}>
            <Button variant="primary" size="small" icon={state.paused ? "play" : "pause"} onClick={p.onTogglePause}>
              {state.paused ? "Run" : "Pause"}
            </Button>
            <Button size="small" icon="reset" onClick={p.onReset}>
              Reset
            </Button>
          </div>
          <div className={s.buttons}>
            <Button size="small" icon="reload" onClick={p.onReload}>
              Reload
            </Button>
            <Button size="small" icon="focus" onClick={p.onAlign}>
              Align
            </Button>
            <Button size="small" icon="copy" onClick={p.onCopyState}>
              Copy state
            </Button>
          </div>
          <Row title="Speed">
            <Select className={s.select} value={p.speed} options={SPEEDS.map((x) => ({ value: x, label: `${x}×` }))} onChange={p.onSpeed} />
          </Row>
          <ValueSlider title="Noise · scale" value={physics.noiseScale} min={0} max={0.5} format={(v) => v.toFixed(2)} onChange={(v) => setPhysics("noiseScale", v)} />
          <ValueSlider title="Noise · rate" value={physics.noiseRate} min={0} max={2} format={(v) => `${v.toFixed(2)} s`} onChange={(v) => setPhysics("noiseRate", v)} />

          <div className={s.subhead}>
            <span>Saved poses</span>
            <Button variant="ghost" size="small" icon="bookmark" onClick={p.onSaveKey}>
              Save current
            </Button>
          </div>
          {p.keyframes.length === 0 && <div className={s.faint}>No saved poses</div>}
          {p.keyframes.map((key) => (
            <div key={key.id} className={s.keyframe}>
              <button type="button" className={s.link} onClick={() => p.onLoadKey(key)}>
                {key.name}
              </button>
              <span className={s.faint}>{swiftDate.toDate(key.savedAt).toLocaleTimeString(undefined, { timeStyle: "short" })}</span>
              <IconButton icon="trash" label="Delete pose" size={13} onClick={() => p.onDeleteKey(key)} />
            </div>
          ))}
        </>,
      )}

      {section(
        "Physics",
        <>
          <ValueSlider title="Gravity" value={physics.gravity} min={0} max={20} format={(v) => `${v.toFixed(2)} m/s²`} onChange={(v) => setPhysics("gravity", v)} />
          <ValueSlider title="Friction" value={physics.friction} min={0} max={1.5} format={(v) => v.toFixed(2)} onChange={(v) => setPhysics("friction", v)} />
          <ValueSlider title="Bounce" value={physics.restitution} min={0} max={0.9} format={(v) => v.toFixed(2)} onChange={(v) => setPhysics("restitution", v)} />
          <Row title="Timestep">
            <Select
              className={s.select}
              value={TIMESTEPS.find((t) => Math.abs(t.value - physics.timestep) < 1e-9)?.value ?? physics.timestep}
              options={TIMESTEPS}
              onChange={(v) => setPhysics("timestep", v)}
            />
          </Row>
          <ValueSlider title="Iterations" value={physics.iterations} min={1} max={30} step={1} format={(v) => v.toFixed(0)} onChange={(v) => setPhysics("iterations", v)} />
          <SwitchLine title="Self-collisions" on={physics.selfCollision} onChange={(v) => setPhysics("selfCollision", v)} />
        </>,
      )}

      {section(
        "Rendering",
        <>
          <SwitchLine title="Contacts" on={render.contacts} onChange={(v) => setRender("contacts", v)} />
          <SwitchLine title="Joint axes" on={render.joints} onChange={(v) => setRender("joints", v)} />
          <SwitchLine title="Collision shapes" on={render.collision} onChange={(v) => setRender("collision", v)} />
          <SwitchLine title="Centers of mass" on={render.com} onChange={(v) => setRender("com", v)} />
          <SwitchLine title="Transparent robot" on={render.transparent} onChange={(v) => setRender("transparent", v)} />
          <SwitchLine title="Grid" on={render.grid} onChange={(v) => setRender("grid", v)} />
          <SwitchLine title="Shadows" on={render.shadows} onChange={(v) => setRender("shadows", v)} />
        </>,
      )}

      {section(
        "Info",
        <>
          <Stat title="Time" value={`${state.time.toFixed(2)} s`} />
          <Stat title="Real-time factor" value={`${state.realTimeFactor.toFixed(2)}×`} />
          <Stat title="Physics step" value={`${state.stepMs.toFixed(3)} ms`} />
          <Stat title="Links" value={`${model?.links.length ?? 0}`} />
          <Stat title="Moving joints" value={`${model?.joints.length ?? 0}`} />
          <Stat title="Actuated" value={`${model ? actuatedJoints(model).length : 0}`} />
          <Stat title="Base" value={model?.floating ? "Free" : "Fixed"} />
          <Stat title="Total mass" value={`${(model?.mass ?? 0).toFixed(3)} kg`} />
          <Stat title="Contacts" value={`${state.contacts}`} />
        </>,
      )}

      {section(
        "Sensors",
        <>
          <div className={s.caption}>Estimated force per motor</div>
          {state.joints.map((j) => (
            <Stat key={j.name} title={j.name} value={j.force.toFixed(2)} />
          ))}
          <div className={s.caption}>Contact force per link</div>
          {Object.keys(state.linkForces).length === 0 && <div className={s.faint}>No contacts</div>}
          {Object.entries(state.linkForces)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([name, force]) => (
              <Stat key={name} title={name} value={`${force.toFixed(2)} N`} />
            ))}
        </>,
      )}

      {section(
        "File",
        <div className={s.buttons}>
          <Button size="small" icon="camera" onClick={p.onScreenshot}>
            Screenshot
          </Button>
          <Button size="small" icon="code" onClick={p.onShowModel}>
            View model
          </Button>
        </div>,
      )}
    </div>
  );
}

function Row({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className={s.row}>
      <span>{title}</span>
      {children}
    </div>
  );
}

function SwitchLine({ title, on, onChange }: { title: string; on: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className={s.row}>
      <span>{title}</span>
      <Switch on={on} onChange={onChange} label={title} />
    </div>
  );
}

function Stat({ title, value }: { title: string; value: string }) {
  return (
    <div className={s.row}>
      <span className={s.statTitle}>{title}</span>
      <span className={s.statValue}>{value}</span>
    </div>
  );
}

/** Deslizador con su título y valor. */
function ValueSlider({ title, value, min, max, step, format, onChange }: {
  title: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  format: (v: number) => string;
  onChange: (v: number) => void;
}) {
  return (
    <div className={s.slider}>
      <div className={s.row}>
        <span>{title}</span>
        <span className={s.statValue}>{format(value)}</span>
      </div>
      <Slider value={value} min={min} max={max} step={step} onChange={onChange} />
    </div>
  );
}
