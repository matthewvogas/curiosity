import { useState, type ReactNode } from "react";
import { observer } from "mobx-react-lite";
import { open } from "@tauri-apps/plugin-dialog";
import { useStores } from "@/app/stores";
import { nativePaths } from "@/queries/native";
import { AI_MODELS } from "@/types/chat-types";
import { Button, Card, Dialog, Icon, Section, Select, Spinner, TextInput } from "@/components/ui";
import s from "./settings-screen.module.css";

const EFFORTS = [
  { value: "low", label: "Low (faster)" },
  { value: "medium", label: "Normal" },
  { value: "high", label: "High (hard tasks)" },
];

const PLATFORMS: Record<string, string> = { macos: "macOS", windows: "Windows", linux: "Linux" };

/** Ajustes: conectar Claude con su API key (en el almacén seguro), elegir el modelo, LeRobot y Hugging Face. */
export const SettingsScreen = observer(function SettingsScreen({ onClose }: { onClose: () => void }) {
  const { settings } = useStores();
  const [keyDraft, setKeyDraft] = useState("");
  const [hubDraft, setHubDraft] = useState("");
  const platform = nativePaths().platform;

  async function browsePython() {
    const path = await open({ multiple: false, directory: false, defaultPath: settings.lerobotPython || undefined });
    if (typeof path === "string") settings.setLerobotPython(path);
  }

  return (
    <Dialog
      title="Settings"
      width={620}
      onClose={onClose}
      footer={
        <>
          <div className={s.footerNote}>
            <Icon name="key" size={13} />
            Keys are stored in your system's secure storage (Keychain on macOS, Credential Manager on Windows).
          </div>
          <Button variant="primary" onClick={onClose}>
            Done
          </Button>
        </>
      }
    >
      <div className={s.content}>
        <Section title="Claude">
          <Card padded={false} className={s.group}>
            <Row title="API key" detail="From console.anthropic.com">
              {settings.hasAnthropicKey ? (
                <div className={s.controls}>
                  {settings.testing ? (
                    <Spinner />
                  ) : settings.testResult ? (
                    <span className={s.result} data-ok={settings.testResult.ok} title={settings.testResult.message}>
                      <Icon name={settings.testResult.ok ? "check" : "warning"} size={13} />
                      {settings.testResult.message}
                    </span>
                  ) : (
                    <span className={s.muted}>Key saved</span>
                  )}
                  <Button size="small" disabled={settings.testing} onClick={() => void settings.testConnection()}>
                    Test
                  </Button>
                  <Button size="small" variant="danger" onClick={() => void settings.removeAnthropicKey()}>
                    Remove
                  </Button>
                </div>
              ) : (
                <form
                  className={s.controls}
                  onSubmit={(e) => {
                    e.preventDefault();
                    void settings.saveAnthropicKey(keyDraft);
                    setKeyDraft("");
                  }}
                >
                  <TextInput type="password" className={s.secret} placeholder="sk-ant-…" value={keyDraft} onChange={(e) => setKeyDraft(e.target.value)} />
                  <Button type="submit" size="small" variant="primary" disabled={!keyDraft.trim()}>
                    Save
                  </Button>
                </form>
              )}
            </Row>
            <Row title="Model">
              <Select className={s.select} value={settings.modelID} options={AI_MODELS.map((m) => ({ value: m.id, label: m.name }))} onChange={(v) => settings.setModelID(v)} />
            </Row>
            <Row title="Thinking effort" detail="More effort plans better, but takes longer">
              <Select className={s.select} value={settings.effort} options={EFFORTS} onChange={(v) => settings.setEffort(v)} />
            </Row>
          </Card>
        </Section>

        <Section title="Connected robots">
          <Card padded={false} className={s.group}>
            <Row title="LeRobot Python" detail="The Python of the environment where LeRobot is installed" stacked>
              <div className={s.controls}>
                <TextInput
                  className={s.path}
                  placeholder={platform === "windows" ? "C:\\…\\.venv\\Scripts\\python.exe" : "/…/.venv/bin/python"}
                  value={settings.lerobotPython}
                  onChange={(e) => settings.setLerobotPython(e.target.value)}
                />
                <Button size="small" icon="folder" onClick={() => void browsePython()}>
                  Browse…
                </Button>
              </div>
            </Row>
            <Row title="Hugging Face" detail="Token with write access, to upload datasets and models">
              {settings.hasHubToken ? (
                <div className={s.controls}>
                  <span className={s.muted}>Token saved</span>
                  <Button size="small" variant="danger" onClick={() => void settings.removeHubToken()}>
                    Remove
                  </Button>
                </div>
              ) : (
                <form
                  className={s.controls}
                  onSubmit={(e) => {
                    e.preventDefault();
                    void settings.saveHubToken(hubDraft);
                    setHubDraft("");
                  }}
                >
                  <TextInput type="password" className={s.secret} placeholder="hf_…" value={hubDraft} onChange={(e) => setHubDraft(e.target.value)} />
                  <Button type="submit" size="small" variant="primary" disabled={!hubDraft.trim()}>
                    Save
                  </Button>
                </form>
              )}
            </Row>
          </Card>
        </Section>

        <Section title="About">
          <Card padded={false} className={s.group}>
            <Row title="Curiosity" detail={PLATFORMS[platform] ?? platform}>
              <span className={s.version}>Version 0.1.0</span>
            </Row>
          </Card>
        </Section>
      </div>
    </Dialog>
  );
});

/** Una fila de ajustes: título y explicación a la izquierda, el control a la derecha (o debajo, si es ancho). */
function Row({ title, detail, stacked, children }: { title: string; detail?: string; stacked?: boolean; children: ReactNode }) {
  return (
    <div className={s.row} data-stacked={stacked}>
      <div className={s.rowText}>
        <div className={s.rowTitle}>{title}</div>
        {detail && <div className={s.rowDetail}>{detail}</div>}
      </div>
      <div className={s.rowControl}>{children}</div>
    </div>
  );
}
