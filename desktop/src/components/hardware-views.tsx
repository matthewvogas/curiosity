import { Button, Field, Progress, Section, TextInput } from "@/components/ui";
import { motorModelName, type FoundMotor } from "@/types/hardware-types";
import s from "./hardware-views.module.css";

/** El nombre corto de un puerto serie para mostrar: «usbmodem5A7A…» en macOS; en Windows, «COM3» tal cual. */
export function shortPort(port: string): string {
  return port.replace(/^\/dev\/(cu\.)?/, "");
}

/** Los motores que respondieron, agrupados por modelo: «6 × STS3215». */
function motorSummary(found: FoundMotor[]): string {
  const counts = new Map<string, number>();
  for (const m of found) counts.set(motorModelName(m), (counts.get(motorModelName(m)) ?? 0) + 1);
  return [...counts].map(([name, n]) => `${n} × ${name}`).sort().join(" · ");
}

/**
 * Un robot físico conectado: su nombre y qué motores respondieron.
 * Solo dibuja: datos y acciones llegan por props.
 */
export function HardwareTestView({ port, name, onNameChange, placeholder, connected, testing, progress, result, resultIsError, found, onTest }: {
  port: string;
  name: string;
  onNameChange: (name: string) => void;
  placeholder: string;
  connected: boolean;
  testing: boolean;
  progress: number;
  result: string | null;
  resultIsError: boolean;
  found: FoundMotor[];
  onTest: () => void;
}) {
  return (
    <>
      <Section>
        <div className={s.form}>
          <Field label="Name">
            <TextInput value={name} placeholder={placeholder} disabled={testing} onChange={(e) => onNameChange(e.target.value)} />
          </Field>
          <div className={s.labeled}>
            <span className={s.label}>Port</span>
            <span className={s.mono}>{shortPort(port)}</span>
          </div>
          {found.length > 0 && (
            // Lo que respondió de verdad en la última prueba, no lo que se supone.
            <div className={s.labeled}>
              <span className={s.label}>Motors</span>
              <span>{motorSummary(found)}</span>
            </div>
          )}
        </div>
      </Section>
      <Section>
        <div className={s.form}>
          <div className={s.status}>
            {testing ? (
              <>
                <div className={s.progress}>
                  <Progress value={progress} />
                </div>
                <span className={s.muted}>Looking for motors…</span>
              </>
            ) : result ? (
              <>
                <span className={resultIsError ? s.error : undefined}>{result}</span>
              </>
            ) : !connected ? (
              <>
                <span className={s.muted}>Unplugged</span>
              </>
            ) : (
              <span className={s.muted}>Not tested</span>
            )}
            <span className={s.spacer} />
            <Button variant="primary" size="small" disabled={testing || !connected} onClick={onTest}>
              Test
            </Button>
          </div>
          {found.map((m) => (
            <div key={m.id} className={s.motor}>
              <span className={s.motorID}>ID {m.id}</span>
              <span className={s.muted}>{motorModelName(m)}</span>
              <span className={s.spacer} />
              <span className={s.mutedNum}>{m.position != null ? `position ${m.position}` : ""}</span>
            </div>
          ))}
        </div>
      </Section>
    </>
  );
}
