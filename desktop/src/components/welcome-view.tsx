import { Icon, Logo, type IconName } from "./ui";
import s from "./welcome-view.module.css";

/** La pantalla de inicio cuando no hay nada abierto: simular un robot o conectar uno real. */
export function WelcomeView({ onOpenSimulator, onConnect }: { onOpenSimulator: () => void; onConnect: () => void }) {
  return (
    <div className={s.wrap}>
      <div className={s.hero}>
        <div className={s.mark}>
          <Logo size={30} />
        </div>
        <div className={s.title}>Curiosity</div>
        <div className={s.subtitle}>Load any robot, connect an AI and ask for tasks in your own words.</div>
      </div>
      <div className={s.cards}>
        <StartCard icon="robot" title="Open simulator" detail="Physics simulation with AI. Any URDF or MJCF." onClick={onOpenSimulator} />
        <StartCard icon="link" title="Connect external robot" detail="An arm over USB, with LeRobot." onClick={onConnect} />
      </div>
    </div>
  );
}

function StartCard({ icon, title, detail, onClick }: { icon: IconName; title: string; detail: string; onClick: () => void }) {
  return (
    <button type="button" className={s.card} onClick={onClick}>
      <div className={s.cardIcon}>
        <Icon name={icon} size={18} />
      </div>
      <div>
        <div className={s.cardTitle}>{title}</div>
        <div className={s.cardDetail}>{detail}</div>
      </div>
    </button>
  );
}
