import type { ReactNode } from "react";
import { Button, Icon, IconButton, Progress, type IconName } from "@/components/ui";
import type { DatasetInfo } from "@/types/lerobot-types";
import type { TaskPhase } from "@/utils/task-status";
import s from "./robot-overview.module.css";

// El resumen de un robot real, como la página de un proyecto: sus tareas, todos sus datos y lo que ha
// aprendido. Solo dibuja: datos y acciones llegan por props.

export type OverviewTask = { id: string; title: string; summary: string; phase: TaskPhase; fraction: number | null };

export type OverviewModel = { id: string; title: string; detail: string; ready: boolean; training: boolean; fraction: number | null };

/** «1.2 MB», como el ByteCountFormatter de macOS (base 1000). */
export function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1000;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

export function RobotOverview({ tasks, datasets, models, canRun, onOpenTask, onNewTask, onRevealDataset, onDeleteDataset, onRunModel, onOpenModel }: {
  tasks: OverviewTask[];
  datasets: DatasetInfo[];
  models: OverviewModel[];
  canRun: boolean;
  onOpenTask: (id: string) => void;
  onNewTask: () => void;
  onRevealDataset: (d: DatasetInfo) => void;
  onDeleteDataset: (d: DatasetInfo) => void;
  onRunModel: (id: string) => void;
  onOpenModel: (id: string) => void;
}) {
  return (
    <div className={s.scroll}>
      <div className={s.page}>
        <Group title="Tasks" count={tasks.length}>
          <div className={s.grid}>
            {tasks.map((t) => (
              <TaskCard key={t.id} task={t} onClick={() => onOpenTask(t.id)} />
            ))}
            <button type="button" className={s.newCard} onClick={onNewTask}>
              <Icon name="add" size={18} />
              <span>New task</span>
            </button>
          </div>
        </Group>

        <Group title="Data" count={datasets.length}>
          {datasets.length === 0 ? (
            <div className={s.empty}>No demonstrations yet</div>
          ) : (
            <div className={s.list}>
              {datasets.map((d) => (
                <Row
                  key={`${d.source}:${d.name}`}
                  icon="dataset"
                  title={d.name}
                  detail={`${d.episodes} demonstrations · ${formatBytes(d.bytes)} · ${d.source === "hub" ? "Hugging Face" : "recorded here"}`}
                >
                  <IconButton icon="folder" label="Show in folder" onClick={() => onRevealDataset(d)} />
                  <IconButton icon="trash" label="Delete these demonstrations" onClick={() => onDeleteDataset(d)} />
                </Row>
              ))}
            </div>
          )}
        </Group>

        <Group title="Models" count={models.length}>
          {models.length === 0 ? (
            <div className={s.empty}>No models yet</div>
          ) : (
            <div className={s.list}>
              {models.map((m) => (
                <Row key={m.id} icon="model" title={m.title} detail={m.detail}>
                  {m.training && m.fraction != null ? (
                    <button type="button" className={s.training} onClick={() => onOpenModel(m.id)} title="Watch training">
                      <span className={s.miniProgress}>
                        <Progress value={m.fraction} />
                      </span>
                      <span className={s.percent}>{Math.round(m.fraction * 100)} %</span>
                    </button>
                  ) : (
                    <IconButton icon="chart" label="Watch training" onClick={() => onOpenModel(m.id)} />
                  )}
                  {m.training ? null : m.ready ? (
                    <Button size="small" icon="play" onClick={() => onRunModel(m.id)} disabled={!canRun} title={canRun ? "Let it do it on its own" : "Set up the follower and camera first"}>
                      Run
                    </Button>
                  ) : (
                    <span className={s.unfinished}>Unfinished</span>
                  )}
                </Row>
              ))}
            </div>
          )}
        </Group>
      </div>
    </div>
  );
}

function Group({ title, count, children }: { title: string; count: number; children: ReactNode }) {
  return (
    <section className={s.group}>
      <h2 className={s.groupTitle}>
        {title}
        {count > 0 && <span className={s.count}>{count}</span>}
      </h2>
      {children}
    </section>
  );
}

function Row({ icon, title, detail, children }: { icon: IconName; title: string; detail: string; children: ReactNode }) {
  return (
    <div className={s.row}>
      <span className={s.rowIcon}>
        <Icon name={icon} size={15} />
      </span>
      <div className={s.rowText}>
        <div className={s.rowTitle}>{title}</div>
        <div className={s.rowDetail}>{detail}</div>
      </div>
      <div className={s.rowActions}>{children}</div>
    </div>
  );
}

function TaskCard({ task, onClick }: { task: OverviewTask; onClick: () => void }) {
  const icon: IconName = task.phase === "learned" ? "taskLearned" : task.phase === "training" ? "taskTraining" : "task";
  return (
    <button type="button" className={s.card} onClick={onClick}>
      <span className={s.cardIcon} data-phase={task.phase}>
        <Icon name={icon} size={17} />
      </span>
      <span className={s.cardSpacer} />
      <span className={s.cardTitle}>{task.title}</span>
      <span className={s.cardSummary}>{task.summary}</span>
      {task.fraction != null && <Progress value={task.fraction} />}
    </button>
  );
}
