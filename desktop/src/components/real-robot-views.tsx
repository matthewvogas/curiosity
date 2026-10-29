import { Button, Dialog, Field, IconButton, Section, Select, Switch } from "@/components/ui";
import type { CameraInfo } from "@/types/lerobot-types";
import { jpegDataURL } from "@/utils/codable";
import { shortPort } from "./hardware-views";
import s from "./real-robot-views.module.css";

// Ajustes del robot real. Solo dibujan: datos y acciones llegan por props.

const NONE = "";
const NO_CAMERA = -1;

/** Un selector de texto opcional: «» es ninguno. */
function OptionalSelect({ value, onChange, none, options, disabled }: {
  value: string | null | undefined;
  onChange: (v: string | null) => void;
  none: string;
  options: { value: string; label: string }[];
  disabled?: boolean;
}) {
  return (
    <Select
      value={value ?? NONE}
      disabled={disabled}
      options={[{ value: NONE, label: none }, ...options]}
      onChange={(v) => onChange(v === NONE ? null : v)}
    />
  );
}

const plain = (list: string[]) => list.map((v) => ({ value: v, label: v }));

/** Cómo se arma el robot: su tipo en LeRobot, calibraciones, el leader, el modelo 3D y la cámara. */
export function RobotSetupView(p: {
  robotKinds: string[];
  teleopKinds: string[];
  models: { id: string; name: string }[];
  robotType: string | null;
  onRobotTypeChange: (v: string | null) => void;
  teleopType: string | null;
  onTeleopTypeChange: (v: string | null) => void;
  /** "" = ninguno. */
  modelID: string | null;
  onModelIDChange: (v: string) => void;
  followers: string[];
  leaders: string[];
  otherPorts: string[];
  cameras: CameraInfo[];
  followerID: string | null;
  onFollowerIDChange: (v: string | null) => void;
  leaderPort: string | null;
  onLeaderPortChange: (v: string | null) => void;
  leaderID: string | null;
  onLeaderIDChange: (v: string | null) => void;
  cameraIndex: number | null;
  onCameraIndexChange: (v: number | null) => void;
  extraCameras: string[];
  onExtraCamerasChange: (names: string[]) => void;
  /** JPEG base64. */
  snapshot: string | null;
  onSnapshot: () => void;
  onRefreshCameras: () => void;
}) {
  const others = p.cameras.filter((c) => c.index !== p.cameraIndex);
  return (
    <Section title="Robot">
      <div className={s.form}>
        <Field label="Robot type">
          <OptionalSelect value={p.robotType} onChange={p.onRobotTypeChange} none="Choose…" options={plain(p.robotKinds)} />
        </Field>
        <Field label="Follower calibration">
          <OptionalSelect value={p.followerID} onChange={p.onFollowerIDChange} none="Choose…" options={plain(p.followers)} />
        </Field>
        <Field label="Leader type">
          <OptionalSelect value={p.teleopType} onChange={p.onTeleopTypeChange} none="Choose…" options={plain(p.teleopKinds)} />
        </Field>
        <Field label="Leader port">
          <OptionalSelect
            value={p.leaderPort}
            onChange={p.onLeaderPortChange}
            none="No leader"
            options={p.otherPorts.map((port) => ({ value: port, label: shortPort(port) }))}
          />
        </Field>
        <Field label="Leader calibration">
          <OptionalSelect value={p.leaderID} onChange={p.onLeaderIDChange} none="Choose…" options={plain(p.leaders)} disabled={p.leaderPort == null} />
        </Field>
        <Field label="3D model">
          <Select
            value={p.modelID ?? NONE}
            options={[{ value: NONE, label: "None" }, ...p.models.map((m) => ({ value: m.id, label: m.name }))]}
            onChange={p.onModelIDChange}
          />
        </Field>
        <Field label="Camera">
          <div className={s.row}>
            <Select
              className={s.grow}
              value={p.cameraIndex ?? NO_CAMERA}
              options={[{ value: NO_CAMERA, label: "Choose…" }, ...p.cameras.map((c) => ({ value: c.index, label: `${c.name} (${c.index})` }))]}
              onChange={(v) => p.onCameraIndexChange(v === NO_CAMERA ? null : v)}
            />
            <Button size="small" disabled={p.cameraIndex == null} onClick={p.onSnapshot}>
              Preview
            </Button>
            <IconButton icon="reload" label="Search for cameras again" onClick={p.onRefreshCameras} />
          </div>
        </Field>
        {p.snapshot && <img className={s.preview} src={jpegDataURL(p.snapshot)} alt="Camera preview" />}
        {others.length > 0 && (
          <div className={s.extras} title="Also shown in Live">
            <span className={s.label}>Other cameras in Live</span>
            <div className={s.extraList}>
              {others.map((c) => (
                <label key={c.index} className={s.extra}>
                  <span>{c.name}</span>
                  <Switch
                    on={p.extraCameras.includes(c.name)}
                    label={c.name}
                    onChange={(on) => p.onExtraCamerasChange(on ? [...p.extraCameras, c.name] : p.extraCameras.filter((n) => n !== c.name))}
                  />
                </label>
              ))}
            </div>
          </div>
        )}
        {p.followers.length === 0 && <span className={s.footer}>No calibrations found. Run lerobot-calibrate.</span>}
      </div>
    </Section>
  );
}

/**
 * Ajuste rápido antes de probar un modelo: qué cámara es cada una de las que el modelo espera y qué calibración.
 * Se muestra en su propio diálogo (cerrarlo es «Done»).
 */
export function RunSetupView({ modelCameras, cameras, followers, followerID, onFollowerIDChange, slots, onSlotsChange, previews, onPreview, onRefreshCameras, onDone }: {
  modelCameras: string[];
  cameras: CameraInfo[];
  followers: string[];
  followerID: string | null;
  onFollowerIDChange: (v: string | null) => void;
  slots: (number | null)[];
  onSlotsChange: (slots: (number | null)[]) => void;
  /** Índice de cámara → JPEG base64. */
  previews: Record<number, string>;
  onPreview: (index: number) => void;
  onRefreshCameras: () => void;
  onDone: () => void;
}) {
  const setSlot = (slot: number, v: number | null) => {
    const next = [...slots, ...new Array<number | null>(Math.max(0, modelCameras.length - slots.length)).fill(null)];
    next[slot] = v;
    onSlotsChange(next);
  };
  return (
    <Dialog onClose={onDone} width={520}>
    <div className={s.run}>
      <Section
        title={modelCameras.length === 1 ? "Camera" : "Cameras"}
        action={<IconButton icon="reload" label="Search for cameras again" onClick={onRefreshCameras} />}
      >
        <div className={s.form}>
          {modelCameras.map((name, slot) => {
            const index = slots[slot] ?? null;
            const preview = index != null ? previews[index] : undefined;
            return (
              <div key={slot} className={s.form}>
                <Field label={`«${name}»`}>
                  <div className={s.row}>
                    <Select
                      className={s.grow}
                      value={index ?? NO_CAMERA}
                      options={[{ value: NO_CAMERA, label: "Choose…" }, ...cameras.map((c) => ({ value: c.index, label: c.name }))]}
                      onChange={(v) => setSlot(slot, v === NO_CAMERA ? null : v)}
                    />
                    <Button size="small" disabled={index == null} onClick={() => index != null && onPreview(index)}>
                      Preview
                    </Button>
                  </div>
                </Field>
                {preview && <img className={s.previewSmall} src={jpegDataURL(preview)} alt={name} />}
              </div>
            );
          })}
          {modelCameras.length > 1 && <span className={s.footer}>Place each camera where it was during training.</span>}
        </div>
      </Section>
      <Section title="Arm">
        <Field label="Follower calibration">
          <OptionalSelect value={followerID} onChange={onFollowerIDChange} none="Choose…" options={plain(followers)} />
        </Field>
      </Section>
      <div className={s.done}>
        <Button variant="primary" onClick={onDone}>
          Done
        </Button>
      </div>
    </div>
    </Dialog>
  );
}
