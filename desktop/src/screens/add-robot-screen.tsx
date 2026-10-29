import { useEffect } from "react";
import { observer } from "mobx-react-lite";
import { open } from "@tauri-apps/plugin-dialog";
import { useStores } from "@/app/stores";
import { OptionCard } from "@/components/option-card";
import { Button, Callout, Dialog } from "@/components/ui";
import s from "./add-robot-screen.module.css";

/** Abrir un simulador: un robot incluido, la biblioteca de MuJoCo Menagerie o un archivo URDF / MJCF. */
export const AddRobotScreen = observer(function AddRobotScreen({ onClose, onOpenLibrary }: {
  onClose: () => void;
  /** Va a la página de la biblioteca (en macOS era otra hoja encima de esta). */
  onOpenLibrary: () => void;
}) {
  const { robots, library } = useStores();

  useEffect(() => {
    if (!library.catalog) void library.load();
  }, [library]);

  async function importFile() {
    const path = await open({
      multiple: false,
      directory: false,
      filters: [{ name: "URDF or MJCF", extensions: ["urdf", "xml"] }],
    });
    if (typeof path !== "string") return;
    await robots.importModel(path);
    if (!robots.error) onClose();
  }

  return (
    <Dialog title="Open simulator" onClose={onClose} width={520} footer={<Button onClick={onClose}>Close</Button>}>
      <div className={s.content}>
        <div className={s.subtitle}>URDF or MJCF</div>
        <div className={s.options}>
          {robots.included.map((robot) => (
            <OptionCard
              key={robot.id}
              icon="robot"
              title={robot.name}
              detail={robot.summary}
              badge="Default"
              action={() => {
                void robots.addIncluded(robot);
                onClose();
              }}
            />
          ))}
          {robots.included.length > 0 && <div className={s.divider} />}
          <OptionCard
            icon="globe"
            title="Robot library"
            detail={`${library.catalog?.robots.length ?? 0} robots from MuJoCo Menagerie`}
            action={() => {
              onOpenLibrary();
              onClose();
            }}
          />
          <OptionCard icon="file" title="Import a file" detail=".urdf or .xml" action={() => void importFile()} />
        </div>
        {robots.error && (
          <Callout tone="red" icon="warning">
            {robots.error}
          </Callout>
        )}
      </div>
    </Dialog>
  );
});
