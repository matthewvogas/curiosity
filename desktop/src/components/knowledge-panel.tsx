import { useState } from "react";
import { Button, Callout, Spinner, Switch, useMenu, type MenuItem } from "@/components/ui";
import type { KnowledgePackage } from "@/types/knowledge-types";
import type { DatasetInfo } from "@/types/lerobot-types";
import { swiftNumber } from "@/utils/knowledge-prompt";
import s from "./knowledge-panel.module.css";

/**
 * Lo que la IA sabe de una tarea por haber estudiado demostraciones, sin entrenar nada. Elegir qué estudiar
 * (de esta computadora o de Hugging Face), ver el paquete y activarlo para el chat. Solo dibuja: todo por props.
 */
export function KnowledgePanel({ packages, activeID, studying, error, localDatasets, onStudy, onSearchHub, onActivate, onRemove }: {
  packages: KnowledgePackage[];
  activeID: string | null;
  studying: string | null;
  error: string | null;
  localDatasets: DatasetInfo[];
  onStudy: (d: DatasetInfo) => void;
  onSearchHub: () => void;
  onActivate: (id: string | null) => void;
  onRemove: (id: string) => void;
}) {
  const menu = useMenu();
  const items: MenuItem[] = [
    ...localDatasets.filter((d) => d.episodes > 0).map((d) => ({ label: `${d.name} · ${d.episodes} demos`, icon: "dataset" as const, onSelect: () => onStudy(d) })),
    "separator",
    { label: "Search Hugging Face…", icon: "globe", onSelect: onSearchHub },
  ];
  return (
    <div className={s.panel}>
      <span className={s.heading}>Knowledge</span>
      {studying ? (
        <span className={s.studying}>
          <Spinner size={13} />
          {studying}
        </span>
      ) : (
        <div>
          <Button variant="primary" size="small" icon="book" onClick={menu.open}>
            Study demonstrations
          </Button>
          {menu.render(items)}
        </div>
      )}
      {error && <Callout tone="red">{error}</Callout>}
      {packages.map((k) => (
        <PackageCard
          key={k.id}
          pkg={k}
          active={k.id === activeID}
          onToggle={() => onActivate(k.id === activeID ? null : k.id)}
          onRemove={() => onRemove(k.id)}
        />
      ))}
    </div>
  );
}

function PackageCard({ pkg, active, onToggle, onRemove }: { pkg: KnowledgePackage; active: boolean; onToggle: () => void; onRemove: () => void }) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className={s.card} data-active={active}>
      <div className={s.cardHeader}>
        <div className={s.cardTitle}>
          <span className={s.title}>{pkg.title}</span>
          <span className={s.source}>{pkg.source}</span>
        </div>
        <span title={active ? "The AI is using it in the chat" : "Let the AI use it in the chat"}>
          <Switch on={active} onChange={onToggle} label="Use" />
        </span>
      </div>
      <p className={s.summary}>{pkg.summary}</p>
      {expanded && (
        <>
          <Lines title="Stages" lines={pkg.stages.map((st, i) => `${i + 1}. ${st.name} — ${st.check}`)} />
          <Lines title="Poses" lines={pkg.poses.map((p) => `"${p.name}" ${p.note}`)} />
          <Lines title="Segments" lines={pkg.segments.map((sg) => `"${sg.name}" demo ${sg.episode}, ${swiftNumber(sg.from)}–${swiftNumber(sg.to)} s`)} />
          {pkg.tips.length > 0 && <Lines title="Tips" lines={pkg.tips} />}
          <button type="button" className={s.link} data-destructive onClick={onRemove}>
            Remove
          </button>
        </>
      )}
      <button type="button" className={s.link} onClick={() => setExpanded(!expanded)}>
        {expanded ? "Less" : "Show all"}
      </button>
    </div>
  );
}

function Lines({ title, lines }: { title: string; lines: string[] }) {
  return (
    <div className={s.lines}>
      <span className={s.linesTitle}>{title}</span>
      {lines.map((l, i) => (
        <span key={i} className={s.line}>
          {l}
        </span>
      ))}
    </div>
  );
}
