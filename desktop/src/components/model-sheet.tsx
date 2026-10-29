import { useState } from "react";
import { Button, Dialog } from "@/components/ui";
import s from "./model-sheet.module.css";

/** Hoja con el resumen del modelo en texto (el «Print model» de MuJoCo), con opción de copiarlo. */
export function ModelSheet({ title, text, onClose }: { title: string; text: string; onClose: () => void }) {
  const [copied, setCopied] = useState(false);
  return (
    <Dialog
      title={title}
      onClose={onClose}
      width={620}
      height={520}
      footer={
        <>
          <Button
            icon={copied ? "check" : "copy"}
            onClick={() =>
              navigator.clipboard.writeText(text).then(
                () => setCopied(true),
                () => {},
              )
            }
          >
            {copied ? "Copied" : "Copy"}
          </Button>
          <Button variant="primary" onClick={onClose}>
            Close
          </Button>
        </>
      }
    >
      <pre className={s.text}>{text}</pre>
    </Dialog>
  );
}
