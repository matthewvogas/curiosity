import { useCallback, useEffect, useRef, useState } from "react";
import { observer } from "mobx-react-lite";
import { openUrl, revealItemInDir } from "@tauri-apps/plugin-opener";
import { useStores } from "@/app/stores";
import { Pane, Workspace } from "@/components/app-shell";
import { Button, Dialog, IconButton, Tabs } from "@/components/ui";
import { TaskPage, type TaskPageActions, type TaskPageInfo } from "@/components/task-page";
import { TaskEmptyState, RecordingView, RunningView, HubPickerView } from "@/components/teach-views";
import { TrainingLiveView } from "@/components/training-live-view";
import { NotePage } from "@/components/note-page";
import { RobotOverview, type OverviewModel, type OverviewTask } from "@/components/robot-overview";
import { PreflightView } from "@/components/preflight-view";
import { HardwareTestView } from "@/components/hardware-views";
import { RobotSetupView, RunSetupView } from "@/components/real-robot-views";
import { DeviceLiveScreen } from "@/screens/device-live-screen";
import { NoteQueries } from "@/queries/note-queries";
import { TrainQueries } from "@/queries/train-queries";
import { RobotQueries } from "@/queries/robot-queries";
import { PermissionQueries } from "@/queries/permission-queries";
import { Preferences } from "@/queries/preferences";
import { join } from "@/queries/native";
import { Dev, deviceGuess, type Device } from "@/types/hardware-types";
import { POLICIES, type DatasetInfo, type PreflightCheck, type TrainJob } from "@/types/lerobot-types";
import { repoID, trainName, type TeachTask } from "@/types/task-types";
import { TaskStatus } from "@/utils/task-status";
import { AppPaths } from "@/utils/app-paths";
import { Naming } from "@/utils/naming";
import { Units } from "@/utils/units";
import { swiftDate } from "@/utils/codable";
import s from "./device-screen.module.css";

type Action = "teleop" | "record" | "run" | "live";
type Mode = "teach" | "live";
type TaskTab = "steps" | "notes";

const PREFLIGHT_TITLE: Record<Action, string> = {
  record: "Before recording",
  live: "Before connecting",
  teleop: "Before moving with the leader",
  run: "Before running",
};

const START_TITLE: Record<Action, string> = { record: "Start recording", live: "Connect", teleop: "Move", run: "Run on the robot" };

const WARNING: Record<Action, string> = {
  live: "The arm holds its pose.",
  teleop: "The follower jumps to the leader’s pose. Keep them close.",
  record: "The follower jumps to the leader’s pose. Keep them close.",
  run: "It moves on its own. Clear the table. Esc stops it.",
};

const policyName = (id: string) => POLICIES.find((p) => p.id === id)?.name ?? id.toUpperCase();

/**
 * Un robot real (cualquiera de LeRobot). Lo principal: enseñarle una tarea en tres pasos (demostraciones, entrenar,
 * probar). Lo secundario va en el encabezado: moverlo con el leader y sus ajustes. Todo lo que mueve el robot pasa
 * por la revisión previa; los valores por defecto se cambian en la misma página de la tarea.
 */
export const DeviceScreen = observer(function DeviceScreen({ device: given }: { device: Device }) {
  const { devices, lerobot, datasets, training, tasks, live, liveChat } = useStores();
  // El dispositivo al día (devices.update lo reemplaza por una copia).
  const device = devices.devices.find((d) => d.id === given.id) ?? given;

  const [mode, setMode] = useState<Mode>("teach");
  const [taskTab, setTaskTabState] = useState<TaskTab>(() => Preferences.get<TaskTab>("task.tab", "steps"));
  const [showingSettings, setShowingSettings] = useState(false);
  const [showingHub, setShowingHub] = useState(false);
  const [runSetupJob, setRunSetupJob] = useState<TrainJob | null>(null);
  const [runSetupCameras, setRunSetupCameras] = useState<string[]>([]);
  const [previews, setPreviews] = useState<Record<number, string>>({});
  const [snapshot, setSnapshot] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<DatasetInfo | null>(null);
  const [runJob, setRunJob] = useState<string | null>(null);
  const [runningHidden, setRunningHiddenState] = useState<string[]>(() => Preferences.get<string[]>("running.hidden", []));
  const [models, setModels] = useState<{ id: string; name: string }[]>([]);
  const [note, setNote] = useState<{ id: string; html: string } | null>(null);
  // Revisión previa (grabar o probar): cada pieza, sin mover nada.
  const [preflightFor, setPreflightFor] = useState<Action | null>(null);
  const [checks, setChecks] = useState<PreflightCheck[]>([]);
  const [checking, setChecking] = useState(false);
  const checkRun = useRef(0);

  const setTaskTab = (t: TaskTab) => {
    setTaskTabState(t);
    Preferences.set("task.tab", t);
  };
  const setRunningHidden = (h: string[]) => {
    setRunningHiddenState(h);
    Preferences.set("running.hidden", h);
  };

  // ---------- Estado ----------

  const deviceName = device.name || deviceGuess(device) || "Robot";
  const session = lerobot.session;
  const status = (task: TeachTask) => TaskStatus.of(task, datasets.local, training.jobs, training.progress);
  const trainingJob = (task: TeachTask) => status(task).job;
  const selectedTask = tasks.selectedFor(device.id);
  const openTask = session?.active !== true || session?.kind === "teleop" ? selectedTask : null;
  const taskFor = (jobName: string) => tasks.tasks.find((t) => jobName === trainName(t) || jobName.startsWith(trainName(t) + "_"));

  /** El modelo que se va a probar: el elegido en el resumen o el de la tarea abierta. */
  const runTarget = (name: string | null = runJob): TrainJob | null => {
    if (name) return training.jobs.find((j) => j.name === name) ?? null;
    return selectedTask ? trainingJob(selectedTask) : null;
  };

  const lerobotStatusError = typeof lerobot.status === "object" ? `LeRobot didn’t start: ${lerobot.status.failed}` : null;
  const notice = training.message ?? lerobot.error ?? lerobotStatusError;

  const subtitle =
    lerobot.status === "starting" ? "Loading LeRobot…"
    : session?.active === true && session.kind === "teleop" ? "Moving with the leader"
    : devices.isConnected(device.id) ? (device.leaderPort == null ? "Plugged in" : "Plugged in · with leader")
    : "Unplugged";

  /** Cuánto tardaría, medido en los entrenamientos de esta computadora con el mismo modelo. Sin ninguno medido: null. */
  const eta = (task: TeachTask): string | null => {
    for (const job of [...training.jobs].reverse()) {
      const p = training.progress[job.name];
      if (job.policy !== task.policy || !p || p.step <= 0 || !p.elapsed) continue;
      const seconds = Units.seconds(p.elapsed);
      if (seconds == null) continue;
      return "About " + Units.duration((seconds / p.step) * task.steps);
    }
    return null;
  };

  const jobTitle = (job: TrainJob) => taskFor(job.name)?.title ?? job.name;
  const jobDetail = (job: TrainJob) => `${policyName(job.policy)} · ${job.steps.toLocaleString()} steps · batch ${job.batchSize} · ${job.dataset}`;

  // ---------- Efectos ----------

  /** Lo que se puede deducir se elige solo: calibraciones únicas y la cámara externa. */
  const applyDefaults = useCallback(() => {
    if (lerobot.status !== "ready") return;
    devices.update(device.id, (d) => {
      const followers = lerobot.followers(d);
      const leaders = lerobot.leaders(d);
      if (d.followerID == null && followers.length === 1) d.followerID = followers[0];
      if (d.leaderID == null && d.leaderPort != null && leaders.length === 1) d.leaderID = leaders[0];
      // La cámara se recuerda por nombre (los números cambian al enchufar otra).
      if (d.cameraName == null && d.cameraIndex != null) d.cameraName = lerobot.cameras.find((c) => c.index === d.cameraIndex)?.name;
      if (d.cameraIndex == null) {
        const pick = lerobot.cameras.find((c) => c.external) ?? lerobot.cameras[0];
        d.cameraIndex = pick?.index;
        d.cameraName = pick?.name;
      }
    });
  }, [devices, lerobot, device.id]);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      await lerobot.start();
      if (cancelled) return;
      applyDefaults();
      await datasets.load();
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [device.id]);

  const statusKey = typeof lerobot.status === "object" ? "failed" : lerobot.status;
  useEffect(() => applyDefaults(), [statusKey, applyDefaults]);

  // Al terminar una sesión (grabar, por ejemplo), las demostraciones nuevas.
  const active = session?.active;
  const wasActive = useRef(active);
  useEffect(() => {
    if (wasActive.current === true && active === false) void datasets.load();
    wasActive.current = active;
  }, [active, datasets]);

  useEffect(() => {
    void Promise.all([RobotQueries.bundled(), RobotQueries.imported()]).then(([a, b]) =>
      setModels([...a, ...b].map((r) => ({ id: r.id, name: r.name }))),
    );
  }, []);

  // Las notas de la tarea abierta.
  const noteTaskID = taskTab === "notes" ? selectedTask?.id ?? null : null;
  useEffect(() => {
    if (!noteTaskID) return;
    let cancelled = false;
    void NoteQueries.load(noteTaskID).then((html) => !cancelled && setNote({ id: noteTaskID, html }));
    return () => {
      cancelled = true;
    };
  }, [noteTaskID]);

  useEffect(() => {
    if (showingSettings || runSetupJob) void lerobot.refreshCameras();
  }, [showingSettings, runSetupJob, lerobot]);

  useEffect(() => {
    if (!runSetupJob) return;
    void TrainQueries.cameras(runSetupJob).then(setRunSetupCameras);
  }, [runSetupJob]);

  // ---------- Acciones ----------

  /** Abre la revisión previa y la corre. */
  const check = (action: Action, jobName: string | null = runJob) => {
    setPreflightFor(action);
    setChecks([]);
    setChecking(true);
    const n = ++checkRun.current;
    void (async () => {
      const target = action === "run" ? runTarget(jobName) : null;
      const roles = target ? await TrainQueries.cameras(target) : [];
      const result = await lerobot.preflight(device, {
        withLeader: action === "record" || action === "teleop",
        withCamera: action !== "teleop",
        withExtras: action === "live" || action === "run",
        roles,
      });
      if (n !== checkRun.current) return;
      setChecks(result);
      setChecking(false);
    })();
  };

  const run = async (action: Action | null) => {
    // «Probar» desde el resumen: un modelo concreto, aunque no haya una tarea abierta.
    if (action === "run" && runJob) {
      const job = training.jobs.find((j) => j.name === runJob);
      if (job) {
        setRunJob(null);
        const task = taskFor(job.name);
        await lerobot.runPolicy(device, TrainQueries.modelPath(job), task?.title ?? job.dataset, task?.runSeconds ?? 60);
        return;
      }
    }
    if (action === "live") {
      await live.start(device);
      return;
    }
    const task = tasks.selectedFor(device.id);
    if (!task) {
      if (action === "teleop") await lerobot.teleoperate(device);
      return;
    }
    switch (action) {
      case "teleop":
        await lerobot.teleoperate(device);
        break;
      case "record": {
        const remaining = Math.max(1, task.episodes - status(task).demos);
        await lerobot.record(device, task.dataset, task.title, remaining, task.episodeSeconds, task.resetSeconds);
        break;
      }
      case "run": {
        const job = trainingJob(task);
        if (job) await lerobot.runPolicy(device, TrainQueries.modelPath(job), task.title, task.runSeconds);
        break;
      }
    }
  };

  const startTraining = (task: TeachTask) => {
    const name = Naming.unique(trainName(task), new Set(training.jobs.map((j) => j.name)));
    const root = task.hubDataset ? null : join(AppPaths.datasets, task.dataset);
    const policy = POLICIES.find((p) => p.id === task.policy) ?? POLICIES[0];
    void training.start(name, repoID(task), root, policy, task.steps, task.batchSize);
  };

  const openHub = () => {
    setShowingHub(true);
    if (datasets.hub.length === 0) void datasets.search();
  };

  const updateDevice = <K extends keyof Device>(key: K) => (v: Device[K]) => devices.update(device.id, (d) => void (d[key] = v));

  // ---------- Encabezado ----------

  const modeValue: Mode = live.isLive ? "live" : mode;
  const modeLocked = live.isLive || lerobot.isBusy;
  const modeSwitch = (
    <div className={s.modeSwitch} data-disabled={modeLocked} title="Teach or control live">
      <Tabs<Mode>
        variant="segmented"
        tabs={[
          { id: "teach", title: "Teach" },
          { id: "live", title: "Live" },
        ]}
        value={modeValue}
        onChange={(m) => !modeLocked && setMode(m)}
      />
    </div>
  );

  const teleopActive = session?.active === true && session.kind === "teleop";
  const settingsButton = <IconButton icon="settings" label="Robot settings: connection, arms and camera" onClick={() => setShowingSettings(true)} />;
  const liveActions = (
    <>
      {live.isLive && (
        <Button
          size="small"
          icon="stop"
          onClick={() => {
            liveChat?.stop();
            live.stop();
          }}
          disabled={live.isReturning}
          title="Return to start and release"
        >
          Release
        </Button>
      )}
      {settingsButton}
    </>
  );
  const teachActions = (
    <>
      {teleopActive ? (
        <Button size="small" icon="stop" onClick={() => lerobot.stop()} title="Releases the follower’s motors">
          Stop moving
        </Button>
      ) : (
        <Button size="small" variant="ghost" icon="hand" onClick={() => check("teleop")} disabled={lerobot.isBusy} title="Nothing is recorded">
          Move with the leader
        </Button>
      )}
      {settingsButton}
    </>
  );

  // ---------- Hojas ----------

  const probe = devices.probe;
  const probeResult = (() => {
    if (probe.state === "failed") return probe.message;
    if (device.probedAt == null) return null;
    const when = swiftDate.toDate(device.probedAt).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    return device.found.length === 0
      ? `No motors responded (${when}). Check that its power supply is on.`
      : `Connected: ${device.found.length} motors responded (${when}).`;
  })();

  const settingsSheet = showingSettings && (
    <Dialog
      title="Robot settings"
      onClose={() => setShowingSettings(false)}
      width={560}
      height={620}
      footer={
        <Button variant="primary" onClick={() => setShowingSettings(false)}>
          Done
        </Button>
      }
    >
      <div className={s.settings}>
        <HardwareTestView
          port={device.id}
          name={device.name}
          onNameChange={(v: string) => devices.update(device.id, (d) => void (d.name = v))}
          placeholder={deviceGuess(device) ?? "Robot"}
          connected={devices.isConnected(device.id)}
          testing={devices.isProbing}
          progress={probe.state === "running" ? probe.progress : 0}
          result={probeResult}
          resultIsError={probe.state === "failed"}
          found={device.found}
          onTest={() => void devices.test(device.id)}
        />
        <RobotSetupView
          robotKinds={lerobot.robotKinds.map((k) => k.type)}
          teleopKinds={lerobot.teleopKinds.map((k) => k.type)}
          models={models}
          robotType={Dev.robotKind(device)}
          onRobotTypeChange={(v: string | null) => devices.update(device.id, (d) => void (d.robotType = v ?? undefined))}
          teleopType={Dev.teleopKind(device)}
          onTeleopTypeChange={(v: string | null) => devices.update(device.id, (d) => void (d.teleopType = v ?? undefined))}
          modelID={Dev.model(device) ?? ""}
          onModelIDChange={(v: string | null) => devices.update(device.id, (d) => void (d.modelID = v ?? ""))}
          followers={lerobot.followers(device)}
          leaders={lerobot.leaders(device)}
          otherPorts={devices.connectedPorts.filter((p) => p !== device.id)}
          cameras={lerobot.cameras}
          followerID={device.followerID ?? null}
          onFollowerIDChange={(v: string | null) => updateDevice("followerID")(v ?? undefined)}
          leaderPort={device.leaderPort ?? null}
          onLeaderPortChange={(v: string | null) => updateDevice("leaderPort")(v ?? undefined)}
          leaderID={device.leaderID ?? null}
          onLeaderIDChange={(v: string | null) => updateDevice("leaderID")(v ?? undefined)}
          cameraIndex={lerobot.mainCamera(device)}
          onCameraIndexChange={(i: number | null) =>
            devices.update(device.id, (d) => {
              d.cameraIndex = i ?? undefined;
              d.cameraName = lerobot.cameras.find((c) => c.index === i)?.name;
              d.extraCameraNames = Dev.extraNames(d).filter((n) => n !== d.cameraName);
            })
          }
          extraCameras={Dev.extraNames(device)}
          onExtraCamerasChange={(v: string[]) => devices.update(device.id, (d) => void (d.extraCameraNames = v))}
          snapshot={snapshot}
          onSnapshot={() => {
            const i = lerobot.mainCamera(device);
            if (i != null) void lerobot.snapshot(i).then(setSnapshot);
          }}
          onRefreshCameras={() => void lerobot.refreshCameras()}
        />
      </div>
    </Dialog>
  );

  /** «Cameras and arm…» del paso 3: cada cámara que el modelo espera ↔ una cámara conectada. */
  const runSetupSheet = runSetupJob && (
    <RunSetupView
      modelCameras={runSetupCameras.length === 0 ? ["front"] : runSetupCameras}
      cameras={lerobot.cameras}
      followers={lerobot.followers(device)}
      followerID={device.followerID ?? null}
      onFollowerIDChange={(v: string | null) => updateDevice("followerID")(v ?? undefined)}
      slots={[lerobot.mainCamera(device), ...lerobot.extraCameras(device).map((e) => e.index)]}
      onSlotsChange={(slots: (number | null)[]) => {
        const picked = slots.map((i) => (i == null ? null : lerobot.cameras.find((c) => c.index === i)?.name ?? null));
        devices.update(device.id, (d) => {
          const main = slots[0];
          if (main != null) {
            d.cameraIndex = main;
            d.cameraName = picked[0] ?? undefined;
          }
          const extras = picked.slice(1).filter((n): n is string => n != null && n !== d.cameraName);
          const known = lerobot.cameras.map((c) => c.name);
          d.extraCameraNames = [...extras, ...Dev.extraNames(d).filter((n) => !extras.includes(n) && n !== d.cameraName && !known.includes(n))];
        });
      }}
      previews={previews}
      onPreview={(i: number) => void lerobot.snapshot(i).then((data) => data && setPreviews((p) => ({ ...p, [i]: data })))}
      onRefreshCameras={() => void lerobot.refreshCameras()}
      onDone={() => setRunSetupJob(null)}
    />
  );

  const hubSheet = showingHub && (
    <HubPickerView
      results={datasets.hub}
      query={datasets.query}
      onQueryChange={(q) => datasets.setQuery(q)}
      searching={datasets.searching}
      onSearch={() => void datasets.search()}
      onPick={(d) => {
        if (selectedTask)
          tasks.update(selectedTask.id, (t) => {
            t.hubDataset = true;
            t.dataset = d.id;
          });
        setShowingHub(false);
      }}
      onClose={() => setShowingHub(false)}
    />
  );

  const watched = training.watched;
  const watchedJob = watched ? training.jobs.find((j) => j.name === watched.name) : undefined;
  const liveTraining = watched && watchedJob && (
    <TrainingLiveView
      title={jobTitle(watchedJob)}
      detail={jobDetail(watchedJob)}
      progress={training.progress[watchedJob.name] ?? null}
      watch={watched}
      onStop={() => training.stop(watchedJob)}
      onClose={() => training.watch(null)}
    />
  );

  const preflightSheet = preflightFor && (
    <PreflightView
      title={PREFLIGHT_TITLE[preflightFor]}
      checks={checks}
      leader={
        preflightFor === "record" || preflightFor === "teleop"
          ? {
              ports: devices.connectedPorts.filter((p) => p !== device.id),
              calibrations: lerobot.leaders(device),
              port: device.leaderPort ?? null,
              onPortChange: (v: string | null) => updateDevice("leaderPort")(v ?? undefined),
              id: device.leaderID ?? null,
              onIDChange: (v: string | null) => updateDevice("leaderID")(v ?? undefined),
            }
          : null
      }
      checking={checking}
      warning={WARNING[preflightFor]}
      startTitle={START_TITLE[preflightFor]}
      onRetry={() => check(preflightFor)}
      onStart={() => {
        const action = preflightFor;
        setPreflightFor(null);
        void run(action);
      }}
      onCancel={() => setPreflightFor(null)}
      onFix={(key: string) => {
        const action = preflightFor;
        setPreflightFor(null);
        // Las cámaras de un modelo se eligen en «Cameras and arm…»; lo demás, en los ajustes.
        const job = runTarget();
        if (action === "run" && (key === "cameras" || key === "camera" || key.startsWith("cam")) && job) setRunSetupJob(job);
        else setShowingSettings(true);
      }}
      onOpenPrivacy={() => void openUrl(PermissionQueries.cameraSettingsURL())}
    />
  );

  const deleteSheet = deleting && (
    <Dialog
      title={`Delete “${deleting.name}”?`}
      onClose={() => setDeleting(null)}
      width={420}
      footer={
        <>
          <Button onClick={() => setDeleting(null)}>Cancel</Button>
          <Button
            variant="danger"
            onClick={() => {
              const d = deleting;
              setDeleting(null);
              void datasets.delete(d);
            }}
          >
            Delete
          </Button>
        </>
      }
    >
      <p className={s.muted}>{deleting.source === "hub" ? "It stays on Hugging Face." : `${deleting.episodes} demonstrations. This can’t be undone.`}</p>
    </Dialog>
  );

  const sheets = (
    <>
      {settingsSheet}
      {hubSheet}
      {runSetupSheet}
      {liveTraining}
      {preflightSheet}
      {deleteSheet}
    </>
  );

  // ---------- En vivo: la pantalla en vivo es dueña de todo el espacio de trabajo ----------

  if (mode === "live" || live.isLive) {
    return (
      <>
        <DeviceLiveScreen device={device} robotName={deviceName} onConnect={() => check("live")} header={modeSwitch} headerActions={liveActions} />
        {sheets}
      </>
    );
  }

  // ---------- Enseñar ----------

  const taskPage = (task: TeachTask) => {
    const st = status(task);
    const info: TaskPageInfo = {
      demos: st.demos,
      hubDataset: task.hubDataset ? task.dataset : null,
      policies: POLICIES.map((p) => ({ id: p.id, label: p.needsSmolVLA && lerobot.env?.smolvla !== true ? `${p.name} (not installed)` : p.name })),
      progress: st.progress,
      hasModel: st.hasModel,
      eta: eta(task),
      // El leader se elige en la revisión previa: para empezar basta con el follower y la cámara.
      canRecord: Dev.canRunPolicy(device),
      canRun: Dev.canRunPolicy(device),
      busy: lerobot.isBusy,
      notice,
    };
    const job = st.job;
    const actions: TaskPageActions = {
      onRecord: () => check("record"),
      onHub: openHub,
      onUseOwn: () =>
        tasks.update(task.id, (t) => {
          t.hubDataset = false;
          t.dataset = Naming.slug(t.title);
        }),
      onTrain: () => startTraining(task),
      onStopTraining: () => job && training.stop(job),
      onWatchTraining: job ? () => training.watch(job.name) : null,
      onRun: () => {
        setRunJob(null);
        check("run", null);
      },
      onFixSetup: () => setShowingSettings(true),
      onRunSetup: () => setRunSetupJob(job),
      onRemove: () => tasks.remove(task.id),
    };
    const set = <K extends keyof TeachTask>(key: K) => (v: TeachTask[K]) => tasks.update(task.id, (t) => void (t[key] = v));
    return (
      <TaskPage
        info={info}
        episodes={task.episodes}
        onEpisodesChange={set("episodes")}
        episodeSeconds={task.episodeSeconds}
        onEpisodeSecondsChange={set("episodeSeconds")}
        policy={task.policy}
        onPolicyChange={set("policy")}
        steps={task.steps}
        onStepsChange={set("steps")}
        runSeconds={task.runSeconds}
        onRunSecondsChange={set("runSeconds")}
        actions={actions}
      />
    );
  };

  const overviewTasks: OverviewTask[] = tasks.tasksFor(device.id).map((t) => {
    const st = status(t);
    return { id: t.id, title: t.title, summary: st.summary(t), phase: st.phase, fraction: st.isTraining && st.progress?.total ? st.progress.step / st.progress.total : null };
  });

  const overviewModels: OverviewModel[] = training.jobs.map((j) => {
    const p = training.progress[j.name];
    const started = swiftDate.toDate(j.started).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
    return {
      id: j.name,
      title: jobTitle(j),
      detail: `${policyName(j.policy)} · ${j.steps.toLocaleString()} steps · ${j.dataset} · ${started}`,
      ready: p?.hasModel === true,
      training: p?.running === true,
      fraction: p?.running && p.total ? p.step / p.total : null,
    };
  });

  let content: React.ReactNode;
  if (session?.active && session.kind === "record") {
    content = <RecordingView session={session} frame={lerobot.frame} onNext={() => lerobot.next()} onRedo={() => lerobot.redo()} onStop={() => lerobot.stop()} />;
  } else if (session?.active && session.kind === "rollout") {
    const frames = Object.fromEntries(Object.entries(lerobot.frames).filter((e): e is [string, string] => e[1] != null));
    content = <RunningView session={session} frames={frames} twin={live.twin} hidden={runningHidden} onHiddenChange={setRunningHidden} onStop={() => lerobot.stop()} />;
  } else if (selectedTask) {
    content = (
      <div className={s.task}>
        <div className={s.taskTabs}>
          <Tabs<TaskTab>
            tabs={[
              { id: "steps", title: "Steps", icon: "check" },
              { id: "notes", title: "Notes", icon: "notes" },
            ]}
            value={taskTab}
            onChange={setTaskTab}
          />
        </div>
        <div className={s.taskBody}>
          {taskTab === "notes" ? (
            <NotePage
              key={selectedTask.id}
              html={note && note.id === selectedTask.id ? note.html : null}
              onSave={(html) => {
                const id = selectedTask.id;
                setNote({ id, html });
                void NoteQueries.save(id, html);
              }}
            />
          ) : (
            taskPage(selectedTask)
          )}
        </div>
      </div>
    );
  } else if (tasks.tasksFor(device.id).length === 0) {
    content = <TaskEmptyState onCreate={(title) => void tasks.add(title, device.id)} />;
  } else {
    content = (
      <RobotOverview
        tasks={overviewTasks}
        datasets={datasets.local}
        models={overviewModels}
        canRun={Dev.canRunPolicy(device) && !lerobot.isBusy}
        onOpenTask={(id) => tasks.select(id)}
        onNewTask={() => tasks.setComposingFor(device.id)}
        onRevealDataset={(d) => void revealItemInDir(d.root)}
        onDeleteDataset={setDeleting}
        onRunModel={(id) => {
          setRunJob(id);
          check("run", id);
        }}
        onOpenModel={(id) => training.watch(id)}
      />
    );
  }

  const title = openTask?.title ?? deviceName;
  const sub = openTask == null ? subtitle : deviceName;

  return (
    <>
      <Workspace>
        <Pane
          captionSafe
          title={
            <span className={s.title}>
              <span className={s.titleText}>{title}</span>
              <span className={s.subtitle}>{sub}</span>
            </span>
          }
          center={modeSwitch}
          actions={teachActions}
        >
          {content}
        </Pane>
      </Workspace>
      {sheets}
    </>
  );
});
