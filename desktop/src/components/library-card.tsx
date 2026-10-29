import { useState } from "react";
import { Icon, Progress } from "./ui";
import s from "./library-card.module.css";

/** Un robot de la biblioteca: vista previa, nombre, tipo y el estado (agregar, descargando o ya agregado). */
export function LibraryCard({ name, category, imageURL, added, progress, onAdd }: {
  name: string;
  category: string;
  imageURL: string | null;
  added: boolean;
  /** null = no se está descargando; 0…1 = progreso. */
  progress: number | null;
  /** Descarga y agrega el robot (o lo abre, si ya estaba). */
  onAdd: () => void;
}) {
  const [failed, setFailed] = useState(false);
  const busy = progress != null;
  return (
    <button type="button" className={s.card} data-busy={busy} disabled={busy} onClick={onAdd} title={added ? `Open ${name}` : `Add ${name}`}>
      <div className={s.preview}>
        {imageURL && !failed ? (
          <img src={imageURL} alt="" loading="lazy" draggable={false} onError={() => setFailed(true)} />
        ) : (
          <Icon name="robot" size={28} className={s.placeholder} />
        )}
        {added && !busy && (
          <span className={s.addedMark} title="In my robots">
            <Icon name="check" size={12} strokeWidth={2.25} />
          </span>
        )}
      </div>
      <div className={s.text}>
        <div className={s.name}>{name}</div>
        <div className={s.category}>{category}</div>
      </div>
      <div className={s.footer}>
        {busy ? (
          <div className={s.progress}>
            <Progress value={progress} />
            <span className={s.percent}>{Math.round(progress * 100)}%</span>
          </div>
        ) : added ? (
          <span className={s.status}>In my robots</span>
        ) : (
          <span className={s.add}>
            <Icon name="add" size={13} />
            Add
          </span>
        )}
      </div>
    </button>
  );
}
