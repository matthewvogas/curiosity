import { makeAutoObservable, runInAction } from "mobx";
import { RobotNotesQueries } from "@/queries/robot-notes-queries";
import type { RobotNotesFile } from "@/utils/robot-notes";

/**
 * Las notas de un robot en la pestaña Notes: lo que mide la app (solo lectura), lo que escribe la persona (se guarda
 * solo, medio segundo después de tipear) y lo que aprendió la IA (se puede borrar). El chat lee el archivo en cada
 * mensaje, así que lo que se cambia acá ya cuenta.
 */
export class UseRobotNotes {
  robotID = "";
  notes = "";
  learned: string[] = [];
  facts: string[] | null = null;
  loading = false;
  private saveTimer: ReturnType<typeof setTimeout> | null = null;

  constructor() {
    makeAutoObservable<UseRobotNotes, "saveTimer">(this, { saveTimer: false });
  }

  /** Abre (o vuelve a leer) las notas de un robot y mide sus datos con `facts` (el cuerpo de su chat). */
  async open(robotID: string, facts: () => Promise<string[] | null>) {
    if (robotID !== this.robotID) this.flush();
    this.robotID = robotID;
    this.loading = true;
    const [file, measured] = await Promise.all([
      RobotNotesQueries.load(robotID).catch((): RobotNotesFile => ({ notes: "", learned: [] })),
      facts().catch(() => null),
    ]);
    runInAction(() => {
      if (this.robotID !== robotID) return;
      // Si la persona está escribiendo, no se pisa su texto.
      if (!this.saveTimer) this.notes = file.notes;
      this.learned = file.learned;
      this.facts = measured;
      this.loading = false;
    });
  }

  setNotes(text: string) {
    this.notes = text;
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.flush(), 500);
  }

  removeLesson(index: number) {
    const lesson = this.learned[index];
    this.learned = this.learned.filter((_, i) => i !== index);
    const robotID = this.robotID;
    if (!robotID || lesson == null) return;
    // Sobre el archivo actual: la IA pudo haber agregado otra mientras tanto.
    void RobotNotesQueries.load(robotID)
      .then((file) => RobotNotesQueries.save(robotID, { ...file, learned: file.learned.filter((l) => l !== lesson) }))
      .catch(() => {});
  }

  reveal() {
    this.flush();
    if (this.robotID) void RobotNotesQueries.reveal(this.robotID).catch(() => {});
  }

  /** Guarda ya el texto pendiente. Lo aprendido se toma del archivo: la IA pudo haber agregado algo. */
  private flush() {
    if (!this.saveTimer) return;
    clearTimeout(this.saveTimer);
    this.saveTimer = null;
    const robotID = this.robotID, notes = this.notes;
    if (!robotID) return;
    void RobotNotesQueries.load(robotID)
      .then((file) => RobotNotesQueries.save(robotID, { notes, learned: file.learned }))
      .catch(() => {});
  }
}

