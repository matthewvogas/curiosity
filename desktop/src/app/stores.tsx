import { createContext, useContext, type ReactNode } from "react";
import { UseSettings } from "@/stores/use-settings";
import { UseRobots } from "@/stores/use-robots";
import { UseSimulation } from "@/stores/use-simulation";
import { UseChat } from "@/stores/use-chat";
import { UseLibrary } from "@/stores/use-library";
import { UseDevices } from "@/stores/use-devices";
import { UseLeRobot } from "@/stores/use-lerobot";
import { UseDatasets } from "@/stores/use-datasets";
import { UseTraining } from "@/stores/use-training";
import { UseTasks } from "@/stores/use-tasks";
import { UseLiveRobot } from "@/stores/use-live-robot";
import { UseKnowledge } from "@/stores/use-knowledge";
import { UseSimRecording } from "@/stores/use-sim-recording";
import { UseRobotNotes } from "@/stores/use-robot-notes";

/**
 * Todos los stores de la app, creados una vez (como el init de CuriosityApp en la versión de macOS).
 * Las pantallas los leen con `useStores()`; los componentes nunca: a ellos todo les llega por props.
 */
export function createStores() {
  const settings = new UseSettings();
  const simulation = new UseSimulation(settings);
  const lerobot = new UseLeRobot(settings);
  const datasets = new UseDatasets(lerobot, settings);
  const training = new UseTraining(settings);
  const robots = new UseRobots();
  const library = new UseLibrary(robots);
  const chat = new UseChat(settings, simulation);
  const simRecording = new UseSimRecording(lerobot, simulation);
  const knowledge = new UseKnowledge(settings, lerobot);
  const live = new UseLiveRobot(lerobot, knowledge);
  // La conversación con el robot real (la del simulador es `chat`).
  const liveChat = new UseChat(settings, live);
  const devices = new UseDevices();
  const tasks = new UseTasks();
  // Las notas del robot de cada chat: el simulado y el real (son mesas distintas).
  const simNotes = new UseRobotNotes();
  const liveNotes = new UseRobotNotes();
  return { settings, robots, simulation, chat, library, devices, lerobot, datasets, training, tasks, live, knowledge, simRecording, liveChat, simNotes, liveNotes };
}

export type Stores = ReturnType<typeof createStores>;

const Context = createContext<Stores | null>(null);

export function StoresProvider({ stores, children }: { stores: Stores; children: ReactNode }) {
  return <Context.Provider value={stores}>{children}</Context.Provider>;
}

export function useStores(): Stores {
  const s = useContext(Context);
  if (!s) throw new Error("StoresProvider is missing");
  return s;
}
