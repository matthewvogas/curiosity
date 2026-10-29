import { Icon, type IconName } from "@/components/ui";
import s from "./option-card.module.css";

/** Tarjeta de una opción (agregar robot, proveedor de IA): ícono, título, descripción y estado. */
export function OptionCard({ icon, title, detail, badge, enabled = true, action }: {
  icon: IconName;
  title: string;
  detail: string;
  badge?: string | null;
  enabled?: boolean;
  action: () => void;
}) {
  return (
    <button type="button" className={s.card} disabled={!enabled} onClick={action}>
      <span className={s.icon}>
        <Icon name={icon} size={18} />
      </span>
      <span className={s.text}>
        <span className={s.titleRow}>
          <span className={s.title}>{title}</span>
          {badge && <span className={s.badge}>{badge}</span>}
        </span>
        <span className={s.detail}>{detail}</span>
      </span>
    </button>
  );
}
