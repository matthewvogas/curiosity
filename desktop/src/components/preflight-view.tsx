import { useEffect, useRef } from "react";
import { Button, Dialog, Field, Icon, Select, Spinner, type IconName } from "@/components/ui";
import { preflightTitle, type PreflightCheck } from "@/types/lerobot-types";
import { shortPort } from "./hardware-views";
import s from "./preflight-view.module.css";

/** El leader, para elegirlo ahí mismo cuando la acción lo necesita. */
export type PreflightLeader = {
  ports: string[];
  calibrations: string[];
  port: string | null;
  onPortChange: (port: string | null) => void;
  id: string | null;
  onIDChange: (id: string | null) => void;
};

const ICON: Record<PreflightCheck["state"], IconName> = { ok: "checkCircle", warn: "warning", fail: "failed" };

function fixTitle(key: string): string {
  if (key === "permission") return "Open system settings";
  if (key === "cameras" || key === "camera" || key.startsWith("cam")) return "Choose cameras";
  return "Robot settings";
}

/**
 * Antes de grabar o probar: cada pieza que se va a usar, revisada (sin mover nada), y qué va a pasar.
 * Empezar solo se habilita cuando nada falla. Solo dibuja: todo por props.
 * Se muestra en su propio diálogo (cerrarlo es «Cancel»).
 */
export function PreflightView({ title, checks, leader, checking, warning, startTitle, onRetry, onStart, onCancel, onFix, onOpenPrivacy }: {
  title: string;
  checks: PreflightCheck[];
  /** Si la acción necesita el leader (grabar, moverlo con el leader). */
  leader: PreflightLeader | null;
  checking: boolean;
  warning: string;
  startTitle: string;
  onRetry: () => void;
  onStart: () => void;
  onCancel: () => void;
  /** Arreglar una revisión que falló (recibe su clave). */
  onFix: (key: string) => void;
  onOpenPrivacy: () => void;
}) {
  const failed = checks.some((c) => c.state === "fail");

  // El leader se elige aquí mismo; al cambiarlo se revisa otra vez.
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    if (leader) onRetry();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [leader?.port, leader?.id]);

  return (
    <Dialog onClose={onCancel} width={600}>
    <div className={s.view}>
      <h2 className={s.title}>{title}</h2>
      <div className={s.checks}>
        {checking && checks.length === 0 && (
          <span className={s.checking}>
            <Spinner size={13} /> Checking each part…
          </span>
        )}
        {checks.map((c) => (
          <div key={c.key} className={s.check}>
            <span className={s.icon} data-state={c.state}>
              <Icon name={ICON[c.state]} size={16} />
            </span>
            <div className={s.checkText}>
              <span>{preflightTitle(c)}</span>
              <span className={s.detail}>{c.detail}</span>
              {c.state === "fail" && c.key !== "leader" && (
                <button type="button" className={s.link} onClick={() => (c.key === "permission" ? onOpenPrivacy() : onFix(c.key))}>
                  {fixTitle(c.key)}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>

      {leader && (
        <div className={s.leader}>
          <Field label="Leader port">
            <Select
              value={leader.port ?? ""}
              options={[{ value: "", label: "Choose…" }, ...leader.ports.map((p) => ({ value: p, label: shortPort(p) }))]}
              onChange={(v) => leader.onPortChange(v || null)}
            />
          </Field>
          <Field label="Leader calibration">
            <Select
              value={leader.id ?? ""}
              options={[{ value: "", label: "Choose…" }, ...leader.calibrations.map((c) => ({ value: c, label: c }))]}
              onChange={(v) => leader.onIDChange(v || null)}
            />
          </Field>
        </div>
      )}

      {!failed && checks.length > 0 && <p className={s.warning}>{warning}</p>}

      <div className={s.buttons}>
        <Button disabled={checking} onClick={onRetry}>
          Check again
        </Button>
        <span className={s.spacer} />
        <Button variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
        <Button variant="primary" disabled={checking || failed || checks.length === 0} onClick={onStart}>
          {startTitle}
        </Button>
      </div>
    </div>
    </Dialog>
  );
}
