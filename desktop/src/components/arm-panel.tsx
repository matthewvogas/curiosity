import { Badge, Button, Callout, Spinner } from "@/components/ui";
import type { CameraFit } from "@/types/hardware-types";
import { jpegDataURL } from "@/utils/codable";
import s from "./arm-panel.module.css";

export type ArmCameraRow = { name: string; frame: string | null; fit: CameraFit | null };

/**
 * El brazo que se mueve solo: qué cámaras están calibradas y la calibración guiada (la pinza va a cada punto
 * con «Move» y la persona hace clic donde ve su punta). Solo dibuja: todo por props.
 */
export function ArmPanel({ cameras, calibrating, marked, pointCount, fit, busy, error, disabled, onStart, onMove, onMark, onUndo, onSave, onCancel }: {
  cameras: ArmCameraRow[];
  calibrating: string | null;
  /** Píxeles (0…1) ya marcados. */
  marked: number[][];
  pointCount: number;
  /** El ajuste de lo marcado (desde 6 puntos). */
  fit: CameraFit | null;
  busy: string | null;
  error: string | null;
  disabled?: boolean;
  onStart: (camera: string) => void;
  onMove: (index: number) => void;
  onMark: (x: number, y: number) => void;
  onUndo: () => void;
  onSave: () => void;
  onCancel: () => void;
}) {
  const cam = calibrating != null ? cameras.find((c) => c.name === calibrating) : undefined;
  return (
    <div className={s.panel}>
      <div className={s.intro}>
        <span className={s.heading}>Arm</span>
        <span className={s.caption}>
          The AI points at things in a camera picture and the arm does the whole move on its own, with its kinematics and the limits of its calibration. For
          that the camera has to know where it is relative to the robot: calibrate it once.
        </span>
      </div>
      {cam ? (
        <Wizard cam={cam} marked={marked} pointCount={pointCount} fit={fit} busy={busy} disabled={disabled} onMove={onMove} onMark={onMark} onUndo={onUndo} onSave={onSave} onCancel={onCancel} />
      ) : (
        cameras.map((c) => (
          <div key={c.name} className={s.cameraRow}>
            <div className={s.cameraText}>
              <span>{c.name}</span>
              {c.fit ? (
                <Badge tone={c.fit.errorPx < 8 ? "green" : "amber"} icon="checkCircle">
                  Calibrated · error <span className={s.num}>{c.fit.errorPx.toFixed(1)}</span> px
                </Badge>
              ) : (
                <span className={s.caption}>Not calibrated</span>
              )}
            </div>
            <Button variant="primary" size="small" disabled={disabled || busy != null} onClick={() => onStart(c.name)}>
              {c.fit == null ? "Calibrate" : "Redo"}
            </Button>
          </div>
        ))
      )}
      {error && <Callout tone="red">{error}</Callout>}
    </div>
  );
}

function Wizard({ cam, marked, pointCount, fit, busy, disabled, onMove, onMark, onUndo, onSave, onCancel }: {
  cam: ArmCameraRow;
  marked: number[][];
  pointCount: number;
  fit: CameraFit | null;
  busy: string | null;
  disabled?: boolean;
  onMove: (index: number) => void;
  onMark: (x: number, y: number) => void;
  onUndo: () => void;
  onSave: () => void;
  onCancel: () => void;
}) {
  const next = marked.length;
  const locked = disabled || busy != null;
  return (
    <div className={s.wizard}>
      <span className={s.heading}>Calibrating {cam.name}</span>
      <span className={s.caption}>
        {next < pointCount
          ? `Point ${next + 1} of ${pointCount}: press Move (the arm goes there slowly with the gripper closed), then click the tip of the gripper in the picture.`
          : "All points marked. Save if the error is low."}
      </span>
      <div className={s.picture}>
        {cam.frame ? (
          <div className={s.frame}>
            <img
              src={jpegDataURL(cam.frame)}
              alt={cam.name}
              draggable={false}
              onClick={(e) => {
                if (locked || next >= pointCount) return;
                const r = e.currentTarget.getBoundingClientRect();
                onMark((e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
              }}
              data-clickable={!locked && next < pointCount}
            />
            {marked.map((m, i) => (
              <span key={i} className={s.marker} style={{ left: `${m[0] * 100}%`, top: `${m[1] * 100}%` }}>
                <span className={s.markerLabel}>{i + 1}</span>
              </span>
            ))}
          </div>
        ) : (
          <div className={s.waiting}>
            <Spinner />
          </div>
        )}
      </div>
      <div className={s.row}>
        <Button variant="primary" size="small" icon="move" disabled={locked || next >= pointCount} onClick={() => onMove(next)}>
          Move to point {Math.min(next + 1, pointCount)}
        </Button>
        {busy && (
          <span className={s.busy}>
            <Spinner size={12} />
            {busy}
          </span>
        )}
      </div>
      <div className={s.row}>
        <span className={s.caption}>
          <span className={s.num}>{marked.length}</span> of <span className={s.num}>{pointCount}</span> points
          {fit && (
            <span data-tone={fit.errorPx < 8 ? "green" : "amber"} className={s.toned}>
              {" "}
              · error <span className={s.num}>{fit.errorPx.toFixed(1)}</span> px
            </span>
          )}
        </span>
        <span className={s.spacer} />
        <Button variant="ghost" size="small" disabled={marked.length === 0 || locked} onClick={onUndo}>
          Undo
        </Button>
      </div>
      {fit && fit.errorPx >= 8 && (
        <Callout tone="amber" icon="warning">
          High error: a click may be off, or the 3D model doesn't match the real arm. Undo the odd point or redo.
        </Callout>
      )}
      <div className={s.row}>
        <Button size="small" disabled={locked} onClick={onCancel}>
          Cancel
        </Button>
        <span className={s.spacer} />
        <Button variant="primary" size="small" disabled={fit == null || locked} onClick={onSave}>
          Save
        </Button>
      </div>
    </div>
  );
}
