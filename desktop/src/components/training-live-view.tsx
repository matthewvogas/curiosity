import { useEffect, useRef } from "react";
import { Badge, Button, Dialog, Progress } from "@/components/ui";
import { progressFraction, type LossPoint, type TrainProgress, type TrainWatch } from "@/types/lerobot-types";
import s from "./training-live-view.module.css";

/**
 * Un entrenamiento en vivo: en qué va, cuánto falta, la curva de la pérdida y lo último del registro.
 * Se abre como diálogo. Solo dibuja: datos y acciones por props.
 */
export function TrainingLiveView({ title, detail, progress, watch, onStop, onClose }: {
  title: string;
  detail: string;
  progress: TrainProgress | null;
  watch: TrainWatch | null;
  onStop: (() => void) | null;
  onClose: () => void;
}) {
  const running = progress?.running === true;
  const status = running ? "Training" : progress?.hasModel ? "Finished" : progress?.error ? "Stopped" : "Not running";
  const tone = running ? "amber" : progress?.hasModel ? "green" : progress?.error ? "red" : "neutral";
  const points = watch?.history ?? [];
  const loss = points.at(-1)?.loss ?? progress?.loss;
  const log = watch?.log ?? [];

  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [log.length]);

  return (
    <Dialog
      title={title}
      onClose={onClose}
      width={640}
      footer={
        <>
          {running && onStop && (
            <Button variant="danger" icon="stop" onClick={onStop}>
              Stop training
            </Button>
          )}
          <span className={s.spacer} />
          <Button onClick={onClose}>Close</Button>
        </>
      }
    >
      <div className={s.body}>
        <div className={s.head}>
          <div className={s.detail}>{detail}</div>
          <Badge tone={tone}>{status}</Badge>
        </div>

        {progress?.total != null && (
          <div className={s.progress}>
            <Progress value={progressFraction(progress)} />
            <div className={s.progressLine}>
              <span>
                Step {progress.step.toLocaleString()} of {progress.total.toLocaleString()}
              </span>
              <span>
                {progress.elapsed && `${progress.elapsed} elapsed`}
                {running && progress.remaining && ` · ${progress.remaining} left`}
              </span>
            </div>
          </div>
        )}

        <div className={s.block}>
          <div className={s.blockHead}>
            <span>Loss</span>
            {loss != null && <span className={s.lossValue}>{loss.toFixed(3)}</span>}
          </div>
          {points.length > 1 ? <LossChart points={points} /> : <div className={s.waiting}>Waiting for the first steps</div>}
        </div>

        <div className={s.block}>
          <div className={s.blockHead}>
            <span>Log</span>
          </div>
          <div ref={logRef} className={s.log}>
            {log.map((line, i) => (
              <div key={i} className={s.logLine}>
                {line}
              </div>
            ))}
          </div>
        </div>
      </div>
    </Dialog>
  );
}

const W = 600;
const H = 180;
const PAD = { left: 44, right: 8, top: 8, bottom: 20 };

/** La curva de la pérdida: una polilínea en escala logarítmica, con tres marcas en cada eje. */
function LossChart({ points }: { points: LossPoint[] }) {
  const valid = points.filter((p) => p.loss > 0 && Number.isFinite(p.loss));
  if (valid.length < 2) return <div className={s.waiting}>Waiting for the first steps</div>;
  const x0 = valid[0].step;
  const x1 = Math.max(x0 + 1, valid.at(-1)!.step);
  const logs = valid.map((p) => Math.log10(p.loss));
  let y0 = Math.min(...logs);
  let y1 = Math.max(...logs);
  if (y1 - y0 < 1e-6) {
    y0 -= 0.5;
    y1 += 0.5;
  }
  const iw = W - PAD.left - PAD.right;
  const ih = H - PAD.top - PAD.bottom;
  const px = (step: number) => PAD.left + ((step - x0) / (x1 - x0)) * iw;
  const py = (l: number) => PAD.top + (1 - (l - y0) / (y1 - y0)) * ih;
  const line = valid.map((p, i) => `${px(p.step).toFixed(1)},${py(logs[i]).toFixed(1)}`).join(" ");
  const yTicks = [y1, (y0 + y1) / 2, y0];
  const xTicks = [x0, Math.round((x0 + x1) / 2), x1];
  const fmtLoss = (l: number) => {
    const v = 10 ** l;
    return v >= 10 ? v.toFixed(0) : v >= 1 ? v.toFixed(1) : v.toPrecision(2);
  };
  const fmtStep = (n: number) => (n >= 1000 ? `${Math.round(n / 100) / 10}k` : String(n));

  return (
    <svg className={s.chart} viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Loss curve">
      {yTicks.map((t, i) => (
        <g key={`y${i}`}>
          <line className={s.grid} x1={PAD.left} x2={W - PAD.right} y1={py(t)} y2={py(t)} />
          <text className={s.axis} x={PAD.left - 6} y={py(t)} textAnchor="end" dominantBaseline="middle">
            {fmtLoss(t)}
          </text>
        </g>
      ))}
      {xTicks.map((t, i) => (
        <text key={`x${i}`} className={s.axis} x={px(t)} y={H - 4} textAnchor={i === 0 ? "start" : i === 2 ? "end" : "middle"}>
          {fmtStep(t)}
        </text>
      ))}
      <polyline className={s.curve} points={line} vectorEffect="non-scaling-stroke" />
    </svg>
  );
}
