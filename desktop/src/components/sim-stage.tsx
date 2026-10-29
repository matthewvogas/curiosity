import { useEffect, useRef } from "react";
import { SimulationQueries } from "@/queries/simulation-queries";
import s from "./sim-stage.module.css";

/**
 * El escenario 3D: el motor de simulación dentro de un iframe, llenando su contenedor.
 * Recibe el puente del motor; no decide nada.
 */
export function SimStage({ engine, rightInset = 0 }: {
  engine: SimulationQueries;
  /** Espacio que tapa algo a la derecha: la cámara centra el robot en lo visible. */
  rightInset?: number;
}) {
  const frame = useRef<HTMLIFrameElement>(null);

  useEffect(() => {
    const f = frame.current;
    if (!f) return;
    engine.attach(f);
    return () => engine.detach(f);
  }, [engine]);

  useEffect(() => {
    engine.setInset(rightInset);
  }, [engine, rightInset]);

  return (
    <div className={s.stage}>
      <iframe ref={frame} className={s.frame} src={SimulationQueries.engineURL()} title="Simulation" />
    </div>
  );
}
