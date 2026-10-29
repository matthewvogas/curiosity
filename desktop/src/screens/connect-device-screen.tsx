import { useEffect, useState } from "react";
import { observer } from "mobx-react-lite";
import { useStores } from "@/app/stores";
import { Button, Dialog, Field, Select, Spinner } from "@/components/ui";
import { OptionCard } from "@/components/option-card";
import { shortPort } from "@/components/hardware-views";
import s from "./connect-device-screen.module.css";

/**
 * Conectar robot externo: un SO-101 son dos brazos. Se elige cuál es el follower (el que trabaja) y
 * cuál el leader (el que mueves con la mano para guiarlo).
 */
export const ConnectDeviceScreen = observer(function ConnectDeviceScreen({ onClose }: { onClose: () => void }) {
  const { devices } = useStores();
  const available = devices.available;
  const [follower, setFollower] = useState<string | null>(() => available[0] ?? null);
  const [leader, setLeader] = useState<string | null>(() => available.find((p) => p !== available[0]) ?? null);

  // Al enchufar un brazo, se propone solo.
  const key = available.join("|");
  useEffect(() => {
    let f = follower;
    if (f == null && available[0]) {
      f = available[0];
      setFollower(f);
    }
    if (leader == null) setLeader(available.find((p) => p !== f) ?? null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const add = () => {
    if (follower) devices.add(follower, leader);
    onClose();
  };

  return (
    <Dialog
      onClose={onClose}
      width={500}
      footer={
        <>
          <Button variant="ghost" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" disabled={follower == null} onClick={add}>
            Add
          </Button>
        </>
      }
    >
      <div className={s.body}>
        <div className={s.intro}>
          <h2 className={s.title}>Connect a robot</h2>
          <span className={s.muted}>Plug in both arms and turn on their power.</span>
        </div>

        {available.length === 0 ? (
          <span className={s.looking}>
            <Spinner size={13} />
            Looking for plugged-in arms…
          </span>
        ) : (
          <div className={s.form}>
            <Field label="Follower (the one that works)">
              <Select
                value={follower ?? ""}
                options={[{ value: "", label: "Choose…" }, ...available.map((p) => ({ value: p, label: shortPort(p) }))]}
                onChange={(v) => setFollower(v || null)}
              />
            </Field>
            <Field label="Leader (the one you move)" hint="Unplug one arm to see which port is which.">
              <Select
                value={leader ?? ""}
                options={[{ value: "", label: "No leader" }, ...available.filter((p) => p !== follower).map((p) => ({ value: p, label: shortPort(p) }))]}
                onChange={(v) => setLeader(v || null)}
              />
            </Field>
          </div>
        )}

        <OptionCard icon="robot" title="Other robots" detail="Koch, LeKiwi, OpenArm and more." badge="Coming soon" enabled={false} action={() => {}} />
      </div>
    </Dialog>
  );
});
