import { Button, Section, Slider } from "@/components/ui";
import type { JointInfo, JointState } from "@/types/robot-types";
import { Units } from "@/utils/units";
import s from "./joint-controls.module.css";

/**
 * Control manual, como los paneles «Control» y «Joint» de MuJoCo: un deslizador por actuador
 * (objetivo) y, debajo, dónde está de verdad cada articulación.
 */
export function JointControls({ joints, states, onChange, onClear, onReset }: {
  joints: JointInfo[];
  states: JointState[];
  onChange: (joint: string, value: number) => void;
  onClear: () => void;
  onReset: () => void;
}) {
  const actuated = joints.filter((j) => j.actuated);
  const stateOf = (name: string) => states.find((st) => st.name === name);
  return (
    <div className={s.panel}>
      <Section
        title="Control"
        action={
          <div className={s.actions}>
            <Button variant="ghost" size="small" onClick={onClear}>
              Clear
            </Button>
            <Button variant="ghost" size="small" onClick={onReset}>
              Home pose
            </Button>
          </div>
        }
      >
        {actuated.length === 0 && <div className={s.empty}>This robot has no actuated joints.</div>}
        <div className={s.rows}>
          {actuated.map((joint) => (
            <ControlRow key={joint.name} joint={joint} state={stateOf(joint.name)} onChange={(v) => onChange(joint.name, v)} />
          ))}
        </div>
      </Section>

      <Section title="Joints">
        <div className={s.bars}>
          {joints.map((joint) => (
            <JointBar key={joint.name} joint={joint} state={stateOf(joint.name)} />
          ))}
        </div>
      </Section>
    </div>
  );
}

function range(joint: JointInfo): [number, number] {
  if (joint.lower != null && joint.upper != null && joint.upper > joint.lower) return [joint.lower, joint.upper];
  return joint.type === "prismatic" ? [-0.5, 0.5] : [-Math.PI, Math.PI];
}

function ControlRow({ joint, state, onChange }: { joint: JointInfo; state?: JointState; onChange: (v: number) => void }) {
  const [lo, hi] = range(joint);
  return (
    <div className={s.control}>
      <div className={s.controlHead}>
        <span className={s.name}>{joint.name}</span>
        <span className={s.value}>{state ? Units.format(state.target, joint.type) : "—"}</span>
      </div>
      <Slider value={state?.target ?? 0} min={lo} max={hi} onChange={onChange} />
    </div>
  );
}

/** Barra de solo lectura con la posición real dentro del rango. */
function JointBar({ joint, state }: { joint: JointInfo; state?: JointState }) {
  const [lo, hi] = range(joint);
  const q = state?.q ?? 0;
  const fraction = (Math.min(Math.max(q, lo), hi) - lo) / (hi - lo);
  return (
    <div className={s.bar}>
      <span className={s.barName} title={joint.name}>
        {joint.name}
      </span>
      <div className={s.track}>
        <div className={s.fill} style={{ width: `max(4px, ${fraction * 100}%)` }} />
      </div>
      <span className={s.barValue}>{Units.format(q, joint.type)}</span>
    </div>
  );
}
