import { IconButton, TextArea } from "@/components/ui";
import s from "./robot-notes-panel.module.css";

/**
 * Las notas de un robot, como un CLAUDE.md: lo que la app mide de él, lo que escribe la persona y lo que la IA
 * aprendió. Claude las lee en cada conversación con este robot. Solo dibuja: todo por props.
 */
export function RobotNotesPanel({ facts, notes, learned, onChange, onRemoveLesson, onReveal }: {
  facts: string[] | null;
  notes: string;
  learned: string[];
  onChange: (text: string) => void;
  onRemoveLesson: (index: number) => void;
  onReveal: () => void;
}) {
  return (
    <div className={s.panel}>
      <div className={s.head}>
        <div>
          <div className={s.heading}>Notes</div>
          <div className={s.caption}>Claude reads this in every conversation with this robot.</div>
        </div>
        <IconButton icon="folder" label="Show file" size={14} onClick={onReveal} />
      </div>

      <div className={s.block}>
        <div className={s.label}>Measured</div>
        {facts && facts.length ? (
          <pre className={s.facts}>{facts.join("\n")}</pre>
        ) : (
          <div className={s.empty}>Load the robot to measure it.</div>
        )}
      </div>

      <div className={s.block}>
        <div className={s.label}>Your notes</div>
        <TextArea
          className={s.editor}
          value={notes}
          spellCheck={false}
          placeholder="Things Claude can't see: where things go on the table, the objects you use (size, weight), rules…"
          onChange={(e) => onChange(e.target.value)}
        />
      </div>

      <div className={s.block}>
        <div className={s.label}>Learned</div>
        {learned.length === 0 ? (
          <div className={s.empty}>Claude adds what it learns here.</div>
        ) : (
          <ul className={s.lessons}>
            {learned.map((l, i) => (
              <li key={`${i}-${l}`} className={s.lesson}>
                <span>{l}</span>
                <IconButton icon="close" label="Remove" size={12} className={s.remove} onClick={() => onRemoveLesson(i)} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
