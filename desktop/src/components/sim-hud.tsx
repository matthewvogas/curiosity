import { Icon, Spinner } from "@/components/ui";
import s from "./sim-hud.module.css";

/** Indicador de la simulación en el encabezado: estado, tiempo, velocidad real y contactos. */
export function SimHUD({ time, realTimeFactor, contacts, paused }: { time: number; realTimeFactor: number; contacts: number; paused: boolean }) {
  return (
    <div className={s.hud}>
      <span className={s.status}>
        {paused ? "Paused" : "Running"}
      </span>
      <span className={s.sep} />
      <span className={s.num}>{time.toFixed(1)} s</span>
      <span className={s.num} title="Speed relative to real time">
        {realTimeFactor.toFixed(2)}×
      </span>
      <span className={s.num}>{contacts} contacts</span>
    </div>
  );
}

/** Mensaje centrado sobre el escenario (cargando o error). */
export function StageMessage({ text, isError }: { text: string; isError: boolean }) {
  return (
    <div className={s.message} data-error={isError}>
      {isError ? <Icon name="warning" size={14} /> : <Spinner size={14} />}
      <span>{text}</span>
    </div>
  );
}

/** Aviso corto tras una acción (captura guardada, estado copiado…), junto al indicador. */
export function StageNotice({ text }: { text: string }) {
  return <div className={s.notice}>{text}</div>;
}
