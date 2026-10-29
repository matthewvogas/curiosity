import { useEffect, useState } from "react";
import { observer } from "mobx-react-lite";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { useStores } from "@/app/stores";
import { AppShell, Pane, SidebarTop, Workspace } from "@/components/app-shell";
import { SidebarList, type SidebarPage, type SidebarTask } from "@/components/sidebar-list";
import { WelcomeView } from "@/components/welcome-view";
import { TaskEmptyState } from "@/components/teach-views";
import { Dialog, IconButton } from "@/components/ui";
import { RobotQueries } from "@/queries/robot-queries";
import { Preferences } from "@/queries/preferences";
import { TaskStatus } from "@/utils/task-status";
import { WorkspaceScreen } from "./workspace-screen";
import { DeviceScreen } from "./device-screen";
import { LibraryScreen } from "./library-screen";
import { AddRobotScreen } from "./add-robot-screen";
import { ConnectDeviceScreen } from "./connect-device-screen";
import { SettingsScreen } from "./settings-screen";

/**
 * Ventana principal: mis robots (simulados y reales) a la izquierda y lo elegido a la derecha.
 * Sin nada elegido, la bienvenida (o la biblioteca de robots).
 */
export const RootScreen = observer(function RootScreen() {
  const { robots, devices, tasks, datasets, training, lerobot, settings } = useStores();
  const [sidebarVisible, setSidebarVisible] = useState(() => Preferences.get("sidebar.visible", true));
  const [page, setPage] = useState<SidebarPage>("home");
  const [addingRobot, setAddingRobot] = useState(false);
  const [connecting, setConnecting] = useState(false);

  const toggleSidebar = () =>
    setSidebarVisible((v) => {
      Preferences.set("sidebar.visible", !v);
      return !v;
    });

  // ⌘B / Ctrl+B muestra u oculta la barra lateral; ⌘, / Ctrl+, abre los ajustes.
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key === "b") {
        e.preventDefault();
        toggleSidebar();
      } else if (e.key === ",") {
        e.preventDefault();
        settings.setOpen(true);
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [settings]);

  // Las tareas muestran cuántas demostraciones llevan: hacen falta los datasets (vía LeRobot).
  const hasDevices = devices.devices.length > 0;
  useEffect(() => {
    if (!hasDevices) return;
    void lerobot.start().then(() => datasets.load());
  }, [hasDevices, lerobot, datasets]);

  // Al abrir un robot (también al agregarlo desde la biblioteca) se cierra el dispositivo abierto.
  useEffect(() => {
    if (robots.selectedID) devices.select(null);
  }, [robots.selectedID, devices]);

  const device = devices.selected;
  const robot = device ? null : robots.selected;

  const sidebarTasks: Record<string, SidebarTask[]> = {};
  for (const d of devices.devices) {
    sidebarTasks[d.id] = tasks.tasksFor(d.id).map((t) => {
      const s = TaskStatus.of(t, datasets.local, training.jobs, training.progress);
      return { id: t.id, title: t.title, summary: s.summary(t), phase: s.phase };
    });
  }

  const showSidebar = !sidebarVisible && <IconButton icon="sidebar" label="Show sidebar" onClick={toggleSidebar} />;

  let detail;
  if (device) detail = <DeviceScreen key={device.id} device={device} />;
  else if (robot) detail = <WorkspaceScreen key={robot.id} robot={robot} leading={showSidebar} />;
  else if (page === "library") detail = <LibraryScreen />;
  else
    detail = (
      <Workspace>
        <Pane captionSafe leading={showSidebar} title="Home">
          <WelcomeView onOpenSimulator={() => setAddingRobot(true)} onConnect={() => setConnecting(true)} />
        </Pane>
      </Workspace>
    );


  return (
    <AppShell
      sidebarVisible={sidebarVisible}
      sidebar={
        <>
          <SidebarTop>
            <IconButton icon="sidebar" label="Hide sidebar" onClick={toggleSidebar} />
          </SidebarTop>
          <SidebarList
            page={device || robot ? null : page}
            robots={robots.robots}
            selectedID={device ? null : robots.selectedID}
            devices={devices.devices}
            connectedPorts={devices.connectedPorts}
            selectedDeviceID={devices.selectedID}
            tasks={sidebarTasks}
            selectedTaskID={device ? tasks.selectedID : null}
            onPage={(p) => {
              robots.select(null);
              devices.select(null);
              setPage(p);
            }}
            onSelect={(r) => {
              devices.select(null);
              robots.select(r.id);
            }}
            onSelectDevice={(d) => {
              devices.select(d.id);
              tasks.select(null);
            }}
            onAdd={() => setAddingRobot(true)}
            onConnect={() => setConnecting(true)}
            onRemove={(r) => robots.remove(r)}
            onRemoveDevice={(d) => devices.remove(d.id)}
            onReveal={(r) => revealItemInDir(RobotQueries.filePath(r))}
            onSelectTask={(d, id) => {
              devices.select(d.id);
              tasks.select(id);
            }}
            onNewTask={(d) => tasks.setComposingFor(d.id)}
            onRemoveTask={(id) => tasks.remove(id)}
            onSettings={() => settings.setOpen(true)}
          />
        </>
      }
    >
      {detail}
      {addingRobot && (
        <AddRobotScreen
          onClose={() => setAddingRobot(false)}
          onOpenLibrary={() => {
            robots.select(null);
            devices.select(null);
            setPage("library");
          }}
        />
      )}
      {connecting && <ConnectDeviceScreen onClose={() => setConnecting(false)} />}
      {settings.open && <SettingsScreen onClose={() => settings.setOpen(false)} />}
      {tasks.composingFor && (
        <Dialog title="New task" width={640} onClose={() => tasks.setComposingFor(null)}>
          <TaskEmptyState
            onCreate={(title) => {
              const id = tasks.composingFor;
              if (id) {
                void tasks.add(title, id);
                devices.select(id);
              }
              tasks.setComposingFor(null);
            }}
          />
        </Dialog>
      )}
    </AppShell>
  );
});
