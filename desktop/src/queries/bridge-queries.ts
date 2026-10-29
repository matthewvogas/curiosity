import { invoke, on } from "./native";

type Json = Record<string, any>;

/**
 * El puente con LeRobot (resources/bridge/curiosity_bridge.py), corriendo con el Python donde está
 * instalado LeRobot. Se le habla por líneas JSON: cada orden tiene su respuesta y, mientras algo corre
 * con el robot, el puente manda avisos (`event`). Esta clase no guarda estado de la app: solo el proceso.
 */
export class BridgeQueries {
  onEvent: (json: Json) => void = () => {};
  onExit: (reason: string) => void = () => {};

  private nextID = 1;
  private waiting = new Map<number, { resolve: (j: Json) => void; reject: (e: Error) => void }>();
  private ready: { resolve: () => void; reject: (e: Error) => void } | null = null;
  private running = false;
  private listening: Promise<unknown> | null = null;

  get isRunning() {
    return this.running;
  }

  private listen() {
    this.listening ??= Promise.all([
      on<string>("bridge://line", (line) => this.receive(line)),
      on<string>("bridge://exit", (reason) => this.terminated(reason)),
    ]);
    return this.listening;
  }

  /** Arranca el puente y espera a que LeRobot termine de cargar (unos segundos). */
  async start(python: string, hubToken: string | null): Promise<void> {
    await this.listen();
    if (this.running || (await invoke<boolean>("bridge_running"))) {
      this.running = true;
      return;
    }
    const ready = new Promise<void>((resolve, reject) => (this.ready = { resolve, reject }));
    await invoke("bridge_start", { python, hubToken });
    this.running = true;
    await ready;
  }

  stop() {
    void invoke("bridge_stop"); // el puente detiene lo que esté corriendo y sale
  }

  /** Manda una orden y espera su respuesta. Lanza el error que explique el puente. */
  async request(cmd: string, args: Json = {}): Promise<Json> {
    if (!this.running) throw new Error("The LeRobot bridge isn't running.");
    const id = this.nextID++;
    const reply = new Promise<Json>((resolve, reject) => this.waiting.set(id, { resolve, reject }));
    try {
      await invoke("bridge_send", { line: JSON.stringify({ ...args, id, cmd }) });
    } catch (e) {
      this.waiting.delete(id);
      throw new Error(String(e));
    }
    const json = await reply;
    if (json.ok === true) return json;
    throw new Error(json.error ?? "LeRobot failed without saying why.");
  }

  private receive(line: string) {
    let json: Json;
    try {
      json = JSON.parse(line);
    } catch {
      return;
    }
    const waiter = typeof json.id === "number" ? this.waiting.get(json.id) : undefined;
    if (waiter) {
      this.waiting.delete(json.id);
      waiter.resolve(json);
    } else if (json.event === "ready") {
      this.ready?.resolve();
      this.ready = null;
    } else {
      this.onEvent(json);
    }
  }

  private terminated(reason: string) {
    const error = new Error(reason);
    this.ready?.reject(error);
    this.ready = null;
    for (const w of this.waiting.values()) w.reject(error);
    this.waiting.clear();
    this.running = false;
    this.onExit(reason);
  }
}
