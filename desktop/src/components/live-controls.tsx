import { Button, Slider } from "@/components/ui";
import { RealAgentTools } from "@/utils/real-agent-tools";
import s from "./live-controls.module.css";

/**
 * Control manual del robot real: un deslizador por articulación (a dónde va) con dónde está de verdad.
 * El robot va despacio hacia lo que marques. Solo dibuja: datos y acciones por props.
 */
export function LiveControls({ joints, positions, targets, limits, onChange, onHome, disabled }: {
  joints: string[];
  positions: Record<string, number>;
  targets: Record<string, number>;
  limits: Record<string, [number, number]>;
  onChange: (joint: string, value: number) => void;
  onHome: () => void;
  disabled?: boolean;
}) {
  return (
    <div className={s.panel}>
      <div className={s.header}>
        <span className={s.heading}>Control</span>
        <Button variant="ghost" size="small" onClick={onHome} disabled={disabled} title="Back to the pose it had when connected">
          Starting pose
        </Button>
      </div>
      {joints.map((j) => {
        const range = limits[j];
        if (!range) return null;
        return (
          <div key={j} className={s.joint}>
            <div className={s.row}>
              <span className={s.name}>{j}</span>
              <span className={s.value} title="Where it is now">
                {RealAgentTools.format(positions[j] ?? 0, j)}
              </span>
            </div>
            <Slider value={targets[j] ?? 0} min={range[0]} max={range[1]} onChange={(v) => onChange(j, v)} disabled={disabled} />
          </div>
        );
      })}
    </div>
  );
}
