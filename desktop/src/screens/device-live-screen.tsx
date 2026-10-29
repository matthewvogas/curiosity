import { useEffect, useState, type ReactNode } from "react";
import { observer } from "mobx-react-lite";
import { useStores } from "@/app/stores";
import { Workspace, Pane } from "@/components/app-shell";
import { Button, Callout, Icon, IconButton, Spinner, Switch, Tabs, useMenu, type MenuItem } from "@/components/ui";
import { ChatView } from "@/components/chat-view";
import { DEFAULT_SPLIT, TileLayout, Tile } from "@/components/tile-layout";
import { SimStage } from "@/components/sim-stage";
import { LiveControls } from "@/components/live-controls";
import { ArmPanel } from "@/components/arm-panel";
import { SkillPanel } from "@/components/skill-panel";
import { KnowledgePanel } from "@/components/knowledge-panel";
import { RobotNotesPanel } from "@/components/robot-notes-panel";
import { HubPickerView } from "@/components/teach-views";
import { Preferences } from "@/queries/preferences";
import { TrainQueries } from "@/queries/train-queries";
import { Dev, type Device } from "@/types/hardware-types";
import { jpegDataURL } from "@/utils/codable";
import { UseLiveRobot } from "@/stores/use-live-robot";
import s from "./device-live-screen.module.css";

type PanelTab = "chat" | "control" | "arm" | "model" | "knowledge" | "notes";
const TABS: { id: PanelTab; title: string }[] = [
  { id: "chat", title: "Chat" },
  { id: "control", title: "Control" },
  { id: "arm", title: "Arm" },
  { id: "model", title: "Model" },
  { id: "knowledge", title: "Knowledge" },
  { id: "notes", title: "Notes" },
];

/** Un valor recordado entre sesiones (como @AppStorage). */
function useStored<T>(key: string, fallback: T): [T, (v: T) => void] {
  const [value, setValue] = useState<T>(() => Preferences.get(key, fallback));
  return [value, (v: T) => {
    setValue(v);
    Preferences.set(key, v);
  }];
}

/**
 * El robot real en vivo, como el simulador: las cámaras y el modelo 3D en el centro y, a la derecha, el chat,
 * el control, el brazo, el modelo de órdenes y el conocimiento. Antes de conectar, una sola acción; conectar
 * pasa por la revisión previa (la hace DeviceScreen, con `onConnect`).
 * `header` va en el centro del encabezado (p. ej. Teach / Live) y `headerActions` junto a los botones propios.
 */
export const DeviceLiveScreen = observer(function DeviceLiveScreen({ device, robotName, onConnect, header, headerActions }: {
  device: Device;
  robotName: string;
  onConnect: () => void;
  header?: ReactNode;
  headerActions?: ReactNode;
}) {
  const { live, settings, lerobot, devices, liveChat: chat, knowledge, datasets, training, liveNotes: notes } = useStores();
  const [tab, setTab] = useStored<PanelTab>("live.tab", "chat");
  const [focused, setFocused] = useState(0);
  /** Cuánto ocupan las vistas chicas (se cambia arrastrando el divisor y se recuerda). */
  const [tileSplit, setTileSplit] = useStored<number>("live.tileSplit", DEFAULT_SPLIT);
  /** La proporción de cada cámara (ancho/alto), leída de sus imágenes, para acomodar las vistas sin franjas. */
  const [aspects, setAspects] = useState<Record<string, number>>({});
  const [showingHub, setShowingHub] = useState(false);
  // El modelo de órdenes: cuál, y la última orden de prueba (se recuerdan entre sesiones).
  const [skillPath, setSkillPath] = useStored("live.skillPath", "");
  const [skillInstruction, setSkillInstruction] = useStored("live.skillInstruction", "");
  const [skillSeconds, setSkillSeconds] = useStored("live.skillSeconds", 15);
  const [skillRecent, setSkillRecent] = useStored("live.skillRecent", "");
  const cameraMenu = useMenu();

  // Las cámaras extra o la calibración cambiaron: el robot en vivo usa el dispositivo al día.
  useEffect(() => live.update(device), [device, live]);

  // Cada robot tiene su conversación.
  useEffect(() => {
    const key = "device-" + device.id;
    if (chat.robotID !== key) chat.reset(robotName, key);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [device.id]);

  // Las notas de este robot (real): se releen al abrir la pestaña y al conectarlo o calibrar una cámara.
  useEffect(() => {
    if (tab === "notes") void notes.open("device-" + device.id, () => live.chatRobotFacts());
  }, [tab, device, live.isLive, notes, live]);

  // Los datasets de esta computadora, para estudiarlos.
  useEffect(() => {
    if (live.isLive && tab === "knowledge") void datasets.load();
  }, [live.isLive, tab, datasets]);

  const mainCamera = lerobot.mainCamera(device);
  const extraNames = Dev.extraNames(device);

  /** Activar o quitar una cámara extra; si ya está en vivo, se aplica sin desconectar. */
  const setExtra = (name: string, on: boolean) => {
    const names = on ? [...extraNames, name] : extraNames.filter((n) => n !== name);
    devices.update(device.id, (d) => void (d.extraCameraNames = names));
    if (live.isLive) live.setExtraCameras({ ...device, extraCameraNames: names });
  };

  const study = (repoID: string, root: string | null) =>
    void knowledge.study(repoID, root, Dev.robotKind(device), device.followerID ?? null);

  /** Prueba a mano: la persona escribió la orden y apretó «Run» (eso es la aprobación). */
  const runSkill = () => {
    const text = skillInstruction.trim();
    if (!text) return;
    const recent = [text, ...skillRecent.split("\n").filter((r) => r && r !== text)];
    setSkillRecent(recent.slice(0, 6).join("\n"));
    live.runSkill(text, skillSeconds).catch(() => {});
  };

  /** Guarda la calibración de la cámara en el robot (queda para las próximas veces). */
  const saveCalibration = () => {
    const name = live.calibrating, fit = live.calibrationFit;
    if (!name || !fit) return;
    const calibrations = { ...(device.cameraCalibrations ?? {}), [name]: fit };
    devices.update(device.id, (d) => void (d.cameraCalibrations = calibrations));
    live.update({ ...device, cameraCalibrations: calibrations });
    live.cancelCalibration();
  };

  const hub = showingHub && (
    <HubPickerView
      results={datasets.hub}
      query={datasets.query}
      onQueryChange={(q) => datasets.setQuery(q)}
      searching={datasets.searching}
      onSearch={() => void datasets.search()}
      onPick={(d) => {
        setShowingHub(false);
        study(d.id, null);
      }}
      onClose={() => setShowingHub(false)}
      detail=""
    />
  );

  // ---------- Antes de conectar ----------

  if (!live.isLive) {
    const canConnect = Dev.canRunPolicy(device);
    return (
      <Workspace>
        <Pane captionSafe center={header} actions={headerActions} bodyClassName={s.startBody}>
          <div className={s.start}>
            <div className={s.startIcon}>
              <Icon name="live" size={28} strokeWidth={1.5} />
            </div>
            <h1 className={s.startTitle}>Control it live</h1>
            <Button variant="primary" size="large" disabled={!canConnect || lerobot.isBusy} onClick={onConnect}>
              Connect
            </Button>
            {!canConnect && <span className={s.muted}>Set up the follower and camera first.</span>}
            {/* Qué cámaras se ven en vivo: la principal (la de grabar) y las que actives. */}
            <div className={s.cameraPicker}>
              <div className={s.cameraHeader}>
                <span className={s.cameraHeading}>Cameras</span>
                <IconButton icon="reload" label="Search for cameras again" onClick={() => void lerobot.refreshCameras()} />
              </div>
              {lerobot.cameras.map((c) =>
                c.index === mainCamera ? (
                  <div key={c.index} className={s.cameraRow}>
                    <span className={s.muted}>{c.name} · main</span>
                    <Icon name="checkCircle" size={14} className={s.muted} />
                  </div>
                ) : (
                  <label key={c.index} className={s.cameraRow}>
                    <span>{c.name}</span>
                    <Switch on={extraNames.includes(c.name)} label={c.name} onChange={(on) => setExtra(c.name, on)} />
                  </label>
                ),
              )}
            </div>
            {lerobot.error && <Callout tone="red">{lerobot.error}</Callout>}
          </div>
        </Pane>
      </Workspace>
    );
  }

  // ---------- En vivo ----------

  const cams = live.cameras;
  const newConversation = () => chat.reset(robotName, "device-" + device.id);

  const cameraItems: MenuItem[] = [
    ...lerobot.cameras.map((c): MenuItem =>
      c.index === mainCamera
        ? { label: `${c.name} · main`, icon: "camera", onSelect: () => {} }
        : { label: c.name, icon: extraNames.includes(c.name) ? "check" : "dot", onSelect: () => setExtra(c.name, !extraNames.includes(c.name)) },
    ),
    "separator",
    { label: "Search again", icon: "reload", onSelect: () => void lerobot.refreshCameras() },
  ];

  let content: ReactNode = null;
  switch (tab) {
    case "chat":
      content = (
        <ChatView
          items={chat.items}
          isRunning={chat.isRunning}
          error={chat.error}
          hasKey={settings.hasAnthropicKey}
          robotName={robotName}
          suggestions={["What do you see on the table?", "Open the gripper a little", "Wave by moving the wrist"]}
          conversations={chat.conversations}
          currentID={chat.conversationID}
          onSend={(t) => chat.send(t)}
          onStop={() => chat.stop()}
          onOpenSettings={() => settings.setOpen(true)}
          onNew={newConversation}
          onOpenConversation={(id) => void chat.open(id)}
          onDeleteConversation={(id) => chat.delete(id)}
          onApprove={() => chat.approve()}
          onReject={() => chat.reject()}
        />
      );
      break;
    case "control":
      content = (
        <LiveControls
          joints={lerobot.session?.jointNames ?? []}
          positions={live.joints}
          targets={live.targets}
          limits={live.limits}
          onChange={(j, v) => live.setTarget(j, v)}
          onHome={() => live.home()}
          disabled={!live.isReady}
        />
      );
      break;
    case "arm":
      content = (
        <ArmPanel
          cameras={cams.map((c) => ({ name: c.name, frame: c.frame, fit: live.calibration(c.name) }))}
          calibrating={live.calibrating}
          marked={live.calibrationPairs.map((p) => p.pixel)}
          pointCount={UseLiveRobot.calibrationPoints.length}
          fit={live.calibrationFit}
          busy={live.armBusy}
          error={live.armError}
          disabled={!live.isReady}
          onStart={(c) => live.startCalibration(c)}
          onMove={(i) => void live.moveToCalibrationPoint(i)}
          onMark={(x, y) => void live.markCalibration(x, y)}
          onUndo={() => live.undoCalibrationPoint()}
          onSave={saveCalibration}
          onCancel={() => live.cancelCalibration()}
        />
      );
      break;
    case "model":
      content = (
        <SkillPanel
          trained={training.finished.map((j) => ({ name: j.name, path: TrainQueries.modelPath(j) }))}
          path={skillPath}
          onPathChange={setSkillPath}
          loaded={live.skillModel}
          loading={live.skillLoading}
          error={live.skillError}
          forAI={live.skillForAI}
          onForAIChange={(on) => live.setSkillForAI(on)}
          instruction={skillInstruction}
          onInstructionChange={setSkillInstruction}
          seconds={skillSeconds}
          onSecondsChange={setSkillSeconds}
          running={live.skillRun}
          last={live.skillLast}
          recent={skillRecent.split("\n").filter(Boolean)}
          disabled={!live.isReady}
          onLoad={() => void live.loadSkill(skillPath)}
          onRun={runSkill}
          onStop={() => live.stopSkill()}
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
    case "knowledge":
      content = (
        <KnowledgePanel
          packages={knowledge.packages}
          activeID={knowledge.activeID}
          studying={knowledge.studying}
          error={knowledge.error}
          localDatasets={datasets.local.filter((d) => d.source === "local")}
          onStudy={(d) => study(`local/${d.name}`, d.root)}
          onSearchHub={() => {
            setShowingHub(true);
            if (datasets.hub.length === 0) void datasets.search();
          }}
          onActivate={(id) => knowledge.setActiveID(id)}
          onRemove={(id) => knowledge.remove(id)}
        />
      );
      break;
  }

  const inspector = (
    <Pane
      inspector
      captionSafe
      center={<Tabs variant="segmented" tabs={TABS} value={tab} onChange={setTab} />}
      bodyClassName={tab === "chat" ? s.chatBody : s.panelBody}
    >
      {content}
    </Pane>
  );

  return (
    <Workspace inspector={inspector}>
      <Pane
        center={header}
        actions={
          <>
            <Button variant="ghost" size="small" icon="video" onClick={cameraMenu.open} title="Cameras">
              Cameras
            </Button>
            {cameraMenu.render(cameraItems)}
            {headerActions}
          </>
        }
        bodyClassName={s.stage}
      >
        {/* Las cámaras y el modelo 3D, cada uno en su contenedor. Un clic destaca uno. */}
        <TileLayout
          focused={focused}
          aspects={[...cams.map((c) => aspects[c.key] ?? 16 / 9), 4 / 3]}
          split={tileSplit}
          onSplitChange={setTileSplit}
        >
          {cams.map((cam, i) => (
            <Tile key={cam.key} title={cam.name} focused={i === focused} onTap={() => setFocused(i)}>
              {cam.frame ? (
                <img
                  src={jpegDataURL(cam.frame)}
                  alt={cam.name}
                  draggable={false}
                  onLoad={(e) => {
                    // La forma de cada cámara sale de su propia imagen (16:9, 4:3…).
                    const { naturalWidth: w, naturalHeight: h } = e.currentTarget;
                    const a = w > 0 && h > 0 ? w / h : 0;
                    if (a && Math.abs((aspects[cam.key] ?? 0) - a) > 0.01) setAspects((m) => ({ ...m, [cam.key]: a }));
                  }}
                />
              ) : (
                <Spinner size={18} />
              )}
            </Tile>
          ))}
          <Tile key="3d" title="3D model" focused={focused === cams.length} onTap={() => setFocused(cams.length)}>
            <SimStage engine={live.twin} />
          </Tile>
        </TileLayout>
        <div className={s.status} data-ready={live.isReady}>
          {!live.isReady && <Spinner size={12} />}
          {live.isReturning ? "Returning to its pose…" : live.isReady ? "Live" : "Connecting…"}
        </div>
      </Pane>
      {hub}
    </Workspace>
  );
});
