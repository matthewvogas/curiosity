import type { ReactNode } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Badge, Button, Callout, Icon, IconButton, Kbd, Progress, Select, type IconName } from "@/components/ui";
import { HubQueries } from "@/queries/hub-queries";
import { progressFraction, type TrainProgress } from "@/types/lerobot-types";
import s from "./task-page.module.css";

// La página de una tarea, como una lista de comprobaciones: tres pasos en orden (demostraciones, entrenamiento,
// prueba), cada uno con su estado, sus pocos valores y un botón. Solo dibuja: todo por props.

export type TaskPageInfo = {
  demos: number;
  hubDataset: string | null;
  policies: { id: string; label: string }[];
  progress: TrainProgress | null;
  hasModel: boolean;
  /** Medido en entrenamientos anteriores de esta computadora; null si todavía no hay ninguno. */
  eta: string | null;
  canRecord: boolean;
  canRun: boolean;
  busy: boolean;
  notice: string | null;
};

export type TaskPageActions = {
  onRecord: () => void;
  onHub: () => void;
  onUseOwn: () => void;
  onTrain: () => void;
  onStopTraining: () => void;
  /** Abre el entrenamiento en vivo (null si todavía no hay ninguno). */
  onWatchTraining: (() => void) | null;
  onRun: () => void;
  onFixSetup: () => void;
  onRunSetup: () => void;
  onRemove: () => void;
};

type StepState = "done" | "active" | "pending" | "failed";

const STATE_ICON: Record<StepState, IconName> = { done: "checkCircle", active: "taskTraining", pending: "task", failed: "failed" };

export function TaskPage(props: {
  info: TaskPageInfo;
  episodes: number;
  onEpisodesChange: (v: number) => void;
  episodeSeconds: number;
  onEpisodeSecondsChange: (v: number) => void;
  policy: string;
  onPolicyChange: (v: string) => void;
  steps: number;
  onStepsChange: (v: number) => void;
  runSeconds: number;
  onRunSecondsChange: (v: number) => void;
  actions: TaskPageActions;
}) {
  const { info, actions, episodes, episodeSeconds, policy, steps, runSeconds } = props;
  const p = info.progress;
  const training = p?.running === true;
  const hasData = info.hubDataset != null || info.demos > 0;
  const fraction = p ? progressFraction(p) : 0;

  // 1. Demostraciones
  const demoState: StepState = info.hubDataset != null || info.demos >= episodes ? "done" : info.demos > 0 ? "active" : "pending";
  const demoDetail = info.hubDataset != null ? "Data from Hugging Face" : `${info.demos} of ${episodes} recorded`;

  // 2. Entrenamiento
  const trainState: StepState = training ? "active" : info.hasModel ? "done" : p?.error ? "failed" : "pending";
  const trainDetail = training
    ? `${Math.round(fraction * 100)} %${p?.remaining ? ` · ${p.remaining} left` : ""}`
    : info.hasModel ? "Ready"
    : p?.error ? `Stopped: ${p.error}`
    : "Not trained";

  // 3. Probar: por qué está apagado, o qué esperar cuando no lo está.
  const runHint = !info.hasModel ? "Available once training finishes."
    : training ? "Wait for the training to finish."
    : !info.canRun ? "Set up the follower and camera first."
    : info.busy ? "Stop Live or moving with the leader first."
    : "Esc stops it.";
  const runState: StepState = info.hasModel && !training ? "active" : "pending";

  return (
    <div className={s.page}>
      {info.notice && (
        <Callout tone="red" icon="warning">
          {info.notice}
        </Callout>
      )}

      <ol className={s.steps}>
        <Step
          n={1}
          title="Demonstrations"
          state={demoState}
          detail={demoDetail}
          action={
            info.hubDataset == null && (
              <Button
                variant={demoState === "done" ? "secondary" : "primary"}
                size="small"
                icon="video"
                onClick={actions.onRecord}
                disabled={!info.canRecord || info.busy || info.demos >= episodes}
              >
                {info.demos === 0 ? "Record" : "Keep recording"}
              </Button>
            )
          }
          footer={info.hubDataset == null && (
            <span className={s.keys}>
              <Kbd>→</Kbd> finish <Kbd>←</Kbd> redo <Kbd>Esc</Kbd> save
            </span>
          )}
        >
          {info.hubDataset != null ? (
            <>
              <Row label="Dataset">
                <button type="button" className={s.link} onClick={() => void openUrl(HubQueries.url(info.hubDataset!))} title="Open the dataset on Hugging Face">
                  {info.hubDataset}
                  <Icon name="external" size={12} />
                </button>
              </Row>
              <div className={s.rowEnd}>
                <Button variant="ghost" size="small" onClick={actions.onUseOwn}>
                  Record my own instead
                </Button>
              </div>
            </>
          ) : (
            <>
              <Row label="Goal">
                <Stepper value={episodes} min={5} max={300} step={5} onChange={props.onEpisodesChange} format={(v) => `${v} demonstrations`} />
              </Row>
              <Row label="Length">
                <Stepper value={episodeSeconds} min={10} max={300} step={5} onChange={props.onEpisodeSecondsChange} format={(v) => `Up to ${Math.round(v)} s each`} />
              </Row>
              <div className={s.rowBetween}>
                <Button variant="ghost" size="small" icon="globe" onClick={actions.onHub}>
                  Use data from Hugging Face…
                </Button>
                {!info.canRecord && (
                  <Button variant="ghost" size="small" icon="settings" onClick={actions.onFixSetup}>
                    Set up follower and camera…
                  </Button>
                )}
              </div>
            </>
          )}
        </Step>

        <Step
          n={2}
          title="Training"
          state={trainState}
          detail={trainDetail}
          action={
            training ? (
              <Button size="small" variant="danger" icon="stop" onClick={actions.onStopTraining}>
                Stop
              </Button>
            ) : info.hasModel ? (
              <Button size="small" onClick={actions.onTrain}>
                Train again
              </Button>
            ) : (
              <Button size="small" variant="primary" icon="model" onClick={actions.onTrain} disabled={!hasData}>
                Train
              </Button>
            )
          }
          footer={hasData ? info.eta ?? undefined : "No demonstrations yet."}
        >
          {training && <Progress value={fraction} />}
          <Row label="Model">
            <Select value={policy} options={info.policies.map((x) => ({ value: x.id, label: x.label }))} onChange={props.onPolicyChange} disabled={training} />
          </Row>
          <Row label="Steps">
            <Stepper value={steps} min={1000} max={200_000} step={1000} onChange={props.onStepsChange} disabled={training} format={(v) => `${v.toLocaleString()} steps`} />
          </Row>
          {actions.onWatchTraining && (
            <div className={s.rowEnd}>
              <Button variant="ghost" size="small" icon="chart" onClick={actions.onWatchTraining}>
                {training ? "Watch live" : "View training"}
              </Button>
            </div>
          )}
        </Step>

        <Step
          n={3}
          title="Run"
          state={runState}
          detail={info.hasModel ? "Model ready" : "No model yet"}
          action={
            <Button
              size="small"
              variant={info.hasModel ? "primary" : "secondary"}
              icon="play"
              onClick={actions.onRun}
              disabled={!info.hasModel || training || !info.canRun || info.busy}
            >
              Run on the robot
            </Button>
          }
          footer={runHint}
        >
          <Row label="Each try">
            <Stepper value={runSeconds} min={10} max={600} step={10} onChange={props.onRunSecondsChange} format={(v) => `${Math.round(v)} s per try`} />
          </Row>
          <div className={s.rowEnd}>
            <Button variant="ghost" size="small" icon="camera" onClick={actions.onRunSetup} disabled={!info.hasModel}>
              Cameras and arm…
            </Button>
          </div>
        </Step>
      </ol>

      <div className={s.remove}>
        <Button variant="ghost" size="small" icon="trash" onClick={actions.onRemove}>
          Remove task
        </Button>
      </div>
    </div>
  );
}

/** Un paso: ícono de estado, título y detalle a la izquierda, la acción a la derecha y sus valores debajo. */
function Step({ n, title, state, detail, action, footer, children }: {
  n: number;
  title: string;
  state: StepState;
  detail: string;
  action?: ReactNode;
  footer?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <li className={s.step} data-state={state}>
      <div className={s.stepHead}>
        <span className={s.stepIcon} data-state={state}>
          <Icon name={STATE_ICON[state]} size={16} />
        </span>
        <div className={s.stepText}>
          <div className={s.stepTitle}>
            <span className={s.stepNumber}>{n}</span>
            {title}
            {state === "done" && <Badge tone="green">Done</Badge>}
            {state === "failed" && <Badge tone="red">Stopped</Badge>}
          </div>
          <div className={s.stepDetail}>{detail}</div>
        </div>
        <div className={s.stepAction}>{action}</div>
      </div>
      {children && <div className={s.stepBody}>{children}</div>}
      {footer && <div className={s.stepFooter}>{footer}</div>}
    </li>
  );
}

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className={s.row}>
      <span className={s.rowLabel}>{label}</span>
      <div className={s.rowValue}>{children}</div>
    </div>
  );
}

/** Un valor con − y + (como el Stepper de macOS). */
function Stepper({ value, min, max, step, onChange, format, disabled }: {
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
  format: (v: number) => string;
  disabled?: boolean;
}) {
  return (
    <div className={s.stepper} data-disabled={disabled}>
      <span className={s.stepperValue}>{format(value)}</span>
      <IconButton icon="minus" label="Less" size={13} disabled={disabled || value <= min} onClick={() => onChange(Math.max(min, value - step))} />
      <IconButton icon="add" label="More" size={13} disabled={disabled || value >= max} onClick={() => onChange(Math.min(max, value + step))} />
    </div>
  );
}
