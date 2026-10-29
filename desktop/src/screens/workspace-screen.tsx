import { useEffect, useState, type ReactNode } from "react";
import { observer } from "mobx-react-lite";
import { useStores } from "@/app/stores";
import { Pane, Workspace } from "@/components/app-shell";
import { IconButton, Tabs, useMenu, type MenuItem } from "@/components/ui";
import { ChatView } from "@/components/chat-view";
import { JointControls } from "@/components/joint-controls";
import { SceneControls } from "@/components/scene-controls";
import { RobotNotesPanel } from "@/components/robot-notes-panel";
import { SimulationPanel } from "@/components/simulation-panel";
import { SimHUD, StageMessage, StageNotice } from "@/components/sim-hud";
import { SimStage } from "@/components/sim-stage";
import { ModelSheet } from "@/components/model-sheet";
import { SimRecordBar, SimRecordSheet } from "@/components/sim-record-views";
import { Preferences } from "@/queries/preferences";
import { UseSimulation } from "@/stores/use-simulation";
import { Dev } from "@/types/hardware-types";
import type { Robot } from "@/types/robot-types";
import s from "./workspace-screen.module.css";

type PanelTab = "chat" | "control" | "simulation" | "scene" | "notes";

const TABS: { id: PanelTab; title: string }[] = [
  { id: "chat", title: "Chat" },
  { id: "control", title: "Control" },
  { id: "simulation", title: "Simulation" },
  { id: "scene", title: "Scene" },
  { id: "notes", title: "Notes" },
];

const SPEEDS = [0.25, 0.5, 1, 2];

/**
 * El espacio de trabajo de un robot: el escenario 3D en el panel principal (con los controles de la
 * simulación en su encabezado) y, a la derecha, el inspector con el chat, el control manual, la
 * simulación y la escena.
 */
export const WorkspaceScreen = observer(function WorkspaceScreen({ robot, leading }: {
  robot: Robot;
  /** Lo que la pantalla de arriba quiera poner al principio del encabezado (p. ej. mostrar la barra lateral). */
  leading?: ReactNode;
}) {
  const { simulation, chat, settings, robots, simRecording: recording, devices, simNotes: notes } = useStores();
  const [yaws, setYaws] = useState<Record<number, number>>({});
  // Al seleccionar un objeto (también con un clic en la escena), su giro actual para la lista.
  const selected = simulation.selectedObject;
  useEffect(() => {
    if (selected != null) void simulation.objectYaws().then(setYaws);
  }, [selected, simulation]);

  // Las notas de este robot: se releen al abrir la pestaña (la IA pudo haber aprendido algo) y al cargar el modelo.
  const modelLoaded = simulation.model != null;
  // Se recuerda la última pestaña.
  const [tab, setTabState] = useState<PanelTab>(() => Preferences.get<PanelTab>("panel.tab", "chat"));
  const setTab = (t: PanelTab) => {
    setTabState(t);
    Preferences.set("panel.tab", t);
  };
  useEffect(() => {
    if (tab === "notes") void notes.open(robot.id, () => simulation.chatRobotFacts());
  }, [tab, robot.id, modelLoaded, notes, simulation]);
  const [panelVisible, setPanelVisible] = useState(true);
  const [showingModel, setShowingModel] = useState(false);
  const [showingRecord, setShowingRecord] = useState(false);
  const [closedSections, setClosedSections] = useState<string[]>(() => Preferences.get("panel.sections", ["Info", "Sensors"]));

  const speedMenu = useMenu();
  const viewMenu = useMenu();
  const cameraMenu = useMenu();

  const newConversation = () => chat.reset(robot.name, robot.id);

  // Al abrir (o cambiar de) robot: cargarlo y empezar una conversación nueva.
  useEffect(() => {
    let alive = true;
    robots
      .profile(robot)
      .catch(() => ({}))
      .then((profile) => {
        if (alive) simulation.open(robot, profile);
      });
    chat.reset(robot.name, robot.id);
    return () => {
      alive = false;
    };
  }, [robot.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // Atajos: espacio (pausa), ⌘R (inicio), ⌘N (conversación nueva), ⌥⌘0 (panel).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = !!target?.closest("input, textarea, select, [contenteditable]");
      const mod = e.metaKey || e.ctrlKey;
      if (e.key === " " && !mod && !typing) {
        e.preventDefault();
        simulation.togglePause();
      } else if (mod && !e.altKey && e.key.toLowerCase() === "r") {
        e.preventDefault();
        simulation.reset();
      } else if (mod && !e.altKey && e.key.toLowerCase() === "n") {
        e.preventDefault();
        chat.reset(robot.name, robot.id);
        setTab("chat");
        setPanelVisible(true);
      } else if (mod && e.altKey && e.code === "Digit0") {
        e.preventDefault();
        setPanelVisible((v) => !v);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [robot.id, robot.name]); // eslint-disable-line react-hooks/exhaustive-deps

  const model = simulation.model;
  const state = simulation.state;
  const subtitle = model ? `${model.joints.length} joints · ${model.links.length} links` : "Loading…";

  /** Ideas para empezar, según lo que tiene el robot. */
  const suggestions = ["What do you see in the scene?", "Put a coffee mug on the table", "Wave hello with the arm"];
  if (simulation.objects.length) suggestions.push("Push the red cube to the left");
  if (model?.joints.some((j) => j.name.toLowerCase().includes("grip"))) suggestions.push("Open and close the gripper");

  const leaders = devices.devices.filter(Dev.canTeleoperate);
  const session = recording.session;

  // ---------- Menús de la barra ----------

  const speedItems: MenuItem[] = SPEEDS.map((x) => ({
    label: `${x}×`,
    icon: simulation.speed === x ? "check" : undefined,
    onSelect: () => simulation.setSpeed(x),
  }));

  const viewItems: MenuItem[] = [
    { label: "3/4", icon: "eye", onSelect: () => simulation.view("tres") },
    { label: "Front", icon: "eye", onSelect: () => simulation.view("frente") },
    { label: "Side", icon: "eye", onSelect: () => simulation.view("lado") },
    { label: "Top", icon: "eye", onSelect: () => simulation.view("arriba") },
    "separator",
    ...UseSimulation.viewAngles.map((v): MenuItem => {
      const on = simulation.views.includes(v.name);
      return {
        label: `${v.name} view`,
        icon: on ? "check" : undefined,
        onSelect: () => simulation.setViews(on ? simulation.views.filter((n) => n !== v.name) : [...simulation.views, v.name]),
      };
    }),
  ];

  const cameras = model?.cameras ?? [];
  const cameraItems: MenuItem[] = [
    { label: "None", icon: simulation.activeCamera == null ? "check" : undefined, onSelect: () => simulation.showCamera(null) },
    ...cameras.map((c): MenuItem => ({ label: c, icon: simulation.activeCamera === c ? "check" : undefined, onSelect: () => simulation.showCamera(c) })),
  ];

  const toolbar = (
    <>
      <IconButton
        icon={state.paused ? "play" : "pause"}
        label={state.paused ? "Resume (Space)" : "Pause (Space)"}
        onClick={() => simulation.togglePause()}
      />
      <IconButton icon="step" label="Step forward a few frames" disabled={!state.paused} onClick={() => simulation.step()} />
      <IconButton icon="reset" label="Back to the home pose (⌘R)" onClick={() => simulation.reset()} />
      <span className={s.divider} />
      <button type="button" className={s.speed} title="Speed" onClick={speedMenu.open}>
        {simulation.speed}×
      </button>
      <IconButton icon="views" label="View and views around the scene" onClick={viewMenu.open} />
      <IconButton icon="video" label="Robot camera" active={simulation.activeCamera != null} disabled={cameras.length === 0} onClick={cameraMenu.open} />
      <span className={s.divider} />
      <IconButton icon="camera" label="Screenshot" disabled={!model} onClick={() => void simulation.screenshot()} />
      <IconButton icon="code" label="View model" disabled={!model} onClick={() => setShowingModel(true)} />
      {recording.canRecord && (
        <IconButton
          icon="record"
          label={leaders.length ? "Record demos by moving the simulated robot with your leader" : "Connect a robot and its leader to record in the simulation"}
          disabled={recording.isActive || leaders.length === 0}
          onClick={() => setShowingRecord(true)}
        />
      )}
      <span className={s.divider} />
      <IconButton icon="settings" label="Settings" onClick={() => settings.setOpen(true)} />
      <IconButton
        icon="inspector"
        label={panelVisible ? "Hide the panel (⌥⌘0)" : "Show the panel (⌥⌘0)"}
        active={panelVisible}
        onClick={() => setPanelVisible(!panelVisible)}
      />
      {speedMenu.render(speedItems)}
      {viewMenu.render(viewItems)}
      {cameraMenu.render(cameraItems)}
    </>
  );

  // ---------- Inspector ----------

  let content: ReactNode;
  switch (tab) {
    case "chat":
      content = (
        <ChatView
          items={chat.items}
          isRunning={chat.isRunning}
          error={chat.error}
          hasKey={settings.hasAnthropicKey}
          robotName={robot.name}
          suggestions={suggestions}
          conversations={chat.conversations}
          currentID={chat.conversationID}
          onSend={(t) => chat.send(t)}
          onStop={() => chat.stop()}
          onOpenSettings={() => settings.setOpen(true)}
          onNew={newConversation}
          onOpenConversation={(id) => void chat.open(id)}
          onDeleteConversation={(id) => chat.delete(id)}
        />
      );
      break;
    case "control":
      content = (
        <JointControls
          joints={model?.joints ?? []}
          states={state.joints}
          onChange={(j, v) => simulation.setTarget(j, v)}
          onClear={() => simulation.clearControls()}
          onReset={() => simulation.reset()}
        />
      );
      break;
    case "simulation":
      content = (
        <SimulationPanel
          state={state}
          model={model}
          physics={simulation.physics}
          onPhysics={(p) => simulation.setPhysics(p)}
          render={simulation.render}
          onRender={(r) => simulation.setRender(r)}
          keyframes={simulation.keyframes}
          speed={simulation.speed}
          closed={closedSections}
          onClosed={(c) => {
            setClosedSections(c);
            Preferences.set("panel.sections", c);
          }}
          onTogglePause={() => simulation.togglePause()}
          onReset={() => simulation.reset()}
          onReload={() => simulation.reload()}
          onAlign={() => simulation.align()}
          onCopyState={() => void simulation.copyState()}
          onSpeed={(x) => simulation.setSpeed(x)}
          onSaveKey={() => void simulation.saveKeyframe()}
          onLoadKey={(k) => simulation.loadKeyframe(k)}
          onDeleteKey={(k) => simulation.deleteKeyframe(k)}
          onScreenshot={() => void simulation.screenshot()}
          onShowModel={() => setShowingModel(true)}
        />
      );
      break;
    case "notes":
      content = (
        <RobotNotesPanel
          facts={notes.facts}
          notes={notes.notes}
          learned={notes.learned}
          onChange={(t) => notes.setNotes(t)}
          onRemoveLesson={(i) => notes.removeLesson(i)}
          onReveal={() => notes.reveal()}
        />
      );
      break;
    case "scene":
      content = (
        <SceneControls
          objects={simulation.objects}
          positions={state.objectPositions}
          yaws={yaws}
          open={simulation.selectedObject}
          onOpen={(id) => simulation.selectObject(id)}
          onUpdate={(id, changes) => void simulation.updateObject(id, changes).catch(() => {})}
          onAdd={(o) => void simulation.addObject(o).catch(() => {})}
          onRemove={(id) => simulation.removeObject(id)}
        />
      );
      break;
  }

  const inspector = panelVisible ? (
    <Pane
      inspector
      captionSafe
      center={<Tabs variant="segmented" tabs={TABS} value={tab} onChange={setTab} />}
    >
      {content}
    </Pane>
  ) : undefined;

  return (
    <Workspace inspector={inspector}>
      <Pane
        leading={leading}
        captionSafe={!panelVisible}
        title={
          <>
            <span className={s.title} title={subtitle}>{robot.name}</span>
            <SimHUD time={state.time} realTimeFactor={state.realTimeFactor} contacts={state.contacts} paused={state.paused} />
          </>
        }
        actions={toolbar}
        bodyClassName={s.body}
      >
        <SimStage engine={simulation.engine} rightInset={0} />

        {simulation.error ? (
          <div className={s.center}>
            <StageMessage text={simulation.error} isError />
          </div>
        ) : simulation.loadingText ? (
          <div className={s.center}>
            <StageMessage text={simulation.loadingText} isError={false} />
          </div>
        ) : null}

        <div className={s.hud}>
          {simulation.notice && <StageNotice key={simulation.notice} text={simulation.notice} />}
        </div>

        {session?.active && (
          <div className={s.recordBar}>
            <SimRecordBar session={session} onNext={() => recording.next()} onRedo={() => recording.redo()} onStop={() => recording.stop()} />
          </div>
        )}
      </Pane>

      {showingModel && <ModelSheet title={model?.name ?? robot.name} text={simulation.modelSummary} onClose={() => setShowingModel(false)} />}
      {showingRecord && (
        <SimRecordSheet
          leaders={leaders}
          onStart={(leader, task, episodes, seconds) => {
            setShowingRecord(false);
            void recording.start(leader, task, episodes, seconds, 5);
          }}
          onCancel={() => setShowingRecord(false)}
        />
      )}
    </Workspace>
  );
});
