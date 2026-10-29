import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Marked, type Tokens } from "marked";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Button, Dialog, EmptyState, Icon, IconButton, Spinner, cx } from "@/components/ui";
import type { ApprovalState, ChatItem, ConversationSummary } from "@/types/chat-types";
import { jpegDataURL, swiftDate } from "@/utils/codable";
import s from "./chat-view.module.css";

export type ChatViewProps = {
  items: ChatItem[];
  isRunning: boolean;
  error: string | null;
  hasKey: boolean;
  robotName: string;
  suggestions: string[];
  conversations: ConversationSummary[];
  currentID: string;
  onSend: (text: string) => void;
  onStop: () => void;
  onOpenSettings: () => void;
  onNew: () => void;
  onOpenConversation: (id: string) => void;
  onDeleteConversation: (id: string) => void;
  /** Para el robot real: aprobar o no un movimiento que propone la IA. */
  onApprove?: () => void;
  onReject?: () => void;
  /** Sin la barra de historial y «Nueva» (por defecto va arriba del chat, dentro de la pestaña). */
  hideToolbar?: boolean;
};

/** La conversación: mensajes, acciones de la IA sobre el robot, imágenes que miró y el campo de texto. */
export function ChatView(props: ChatViewProps) {
  const { items, isRunning, error, hasKey, robotName, suggestions, onSend, onStop, onOpenSettings } = props;
  const scroller = useRef<HTMLDivElement>(null);

  // Al llegar algo nuevo, se baja hasta el final.
  useEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
  }, [items.length, isRunning, error]);

  return (
    <div className={s.chat}>
      {!props.hideToolbar && (
        <div className={s.toolbar}>
          <ChatToolbar
            conversations={props.conversations}
            currentID={props.currentID}
            canStartNew={items.length > 0}
            onNew={props.onNew}
            onOpenConversation={props.onOpenConversation}
            onDeleteConversation={props.onDeleteConversation}
          />
        </div>
      )}

      <div className={s.scroll} ref={scroller}>
        {items.length === 0 ? (
          <ChatWelcome robotName={robotName} hasKey={hasKey} suggestions={suggestions} onPick={onSend} onOpenSettings={onOpenSettings} />
        ) : (
          <div className={s.thread}>
            {groupPhotos(items).map((item) =>
              "photos" in item ? (
                <PhotoStrip key={item.id} photos={item.photos} />
              ) : (
                <ChatRow key={item.id} item={item} onApprove={props.onApprove ?? (() => {})} onReject={props.onReject ?? (() => {})} />
              ),
            )}
            {isRunning && <ThinkingRow />}
            {error && <NoticeRow text={error} isError />}
          </div>
        )}
        {items.length === 0 && error && (
          <div className={s.thread}>
            <NoticeRow text={error} isError />
          </div>
        )}
      </div>

      <ChatComposer isRunning={isRunning} enabled={hasKey} robotName={robotName} onSend={onSend} onStop={onStop} />
    </div>
  );
}

// ---------- Barra: historial y conversación nueva ----------

/** Historial y «Nueva conversación», como botones de ícono (para el encabezado del panel). */
export function ChatToolbar({ conversations, currentID, canStartNew, onNew, onOpenConversation, onDeleteConversation }: {
  conversations: ConversationSummary[];
  currentID: string;
  canStartNew: boolean;
  onNew: () => void;
  onOpenConversation: (id: string) => void;
  onDeleteConversation: (id: string) => void;
}) {
  const [anchor, setAnchor] = useState<DOMRect | null>(null);
  return (
    <>
      <IconButton
        icon="history"
        label="History"
        active={!!anchor}
        disabled={conversations.length === 0}
        onClick={(e) => setAnchor(anchor ? null : e.currentTarget.getBoundingClientRect())}
      />
      <IconButton icon="clear" label="New conversation" disabled={!canStartNew} onClick={onNew} />
      {anchor && (
        <HistoryList
          anchor={anchor}
          conversations={conversations}
          currentID={currentID}
          onOpen={(id) => {
            onOpenConversation(id);
            setAnchor(null);
          }}
          onDelete={onDeleteConversation}
          onClose={() => setAnchor(null)}
        />
      )}
    </>
  );
}

/** Conversaciones anteriores con el robot: clic para retomarla; la papelera la borra. */
function HistoryList({ anchor, conversations, currentID, onOpen, onDelete, onClose }: {
  anchor: DOMRect;
  conversations: ConversationSummary[];
  currentID: string;
  onOpen: (id: string) => void;
  onDelete: (id: string) => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const close = (e: Event) => {
      if (e instanceof KeyboardEvent && e.key !== "Escape") return;
      if (e instanceof MouseEvent && ref.current?.contains(e.target as Node)) return;
      onClose();
    };
    // Un cuadro después, para que el clic que lo abrió no lo cierre.
    const t = setTimeout(() => {
      window.addEventListener("mousedown", close);
      window.addEventListener("keydown", close);
      window.addEventListener("blur", onClose);
    });
    return () => {
      clearTimeout(t);
      window.removeEventListener("mousedown", close);
      window.removeEventListener("keydown", close);
      window.removeEventListener("blur", onClose);
    };
  }, [onClose]);
  useEffect(() => {
    if (conversations.length === 0) onClose();
  }, [conversations.length, onClose]);

  const width = 300;
  const left = Math.max(8, Math.min(anchor.right - width, window.innerWidth - width - 8));
  return createPortal(
    <div ref={ref} className={s.history} style={{ top: anchor.bottom + 6, left, width }} role="menu">
      <div className={s.historyTitle}>Conversations</div>
      {conversations.map((c) => (
        <div
          key={c.id}
          className={s.historyRow}
          data-current={c.id === currentID}
          role="menuitem"
          tabIndex={0}
          onClick={() => onOpen(c.id)}
          onKeyDown={(e) => e.key === "Enter" && onOpen(c.id)}
        >
          <div className={s.historyText}>
            <div className={s.historyName}>{c.title}</div>
            <div className={s.historyDate}>
              {swiftDate.toDate(c.updatedAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
            </div>
          </div>
          <IconButton
            icon="trash"
            label="Delete conversation"
            size={13}
            className={s.historyDelete}
            onClick={(e) => {
              e.stopPropagation();
              onDelete(c.id);
            }}
          />
        </div>
      ))}
    </div>,
    document.body,
  );
}

// ---------- Bienvenida ----------

function ChatWelcome({ robotName, hasKey, suggestions, onPick, onOpenSettings }: {
  robotName: string;
  hasKey: boolean;
  suggestions: string[];
  onPick: (text: string) => void;
  onOpenSettings: () => void;
}) {
  if (!hasKey) {
    return (
      <div className={s.welcomeEmpty}>
        <EmptyState icon="key" title="Connect an AI model" detail={`Add your Anthropic API key to talk to ${robotName}.`}>
          <Button variant="primary" icon="settings" onClick={onOpenSettings}>
            Open Settings
          </Button>
        </EmptyState>
      </div>
    );
  }
  return (
    <div className={s.welcome}>
      <div className={s.welcomeTitle}>Talk to {robotName}</div>
      <div className={s.welcomeDetail}>Ask in your own words. The AI looks through the cameras and moves the robot.</div>
      <div className={s.suggestions}>
        {suggestions.map((text) => (
          <button key={text} type="button" className={s.suggestion} onClick={() => onPick(text)}>
            {text}
          </button>
        ))}
      </div>
    </div>
  );
}

// ---------- Renglones ----------

function ChatRow({ item, onApprove, onReject }: { item: ChatItem; onApprove: () => void; onReject: () => void }) {
  const k = item.kind;
  if ("user" in k) {
    return (
      <div className={s.userRow}>
        <div className={s.bubble}>{k.user._0}</div>
      </div>
    );
  }
  if ("assistant" in k) return <AssistantText text={k.assistant._0} />;
  if ("action" in k) return <ActionRow {...k.action} />;
  if ("notice" in k) return <NoticeRow text={k.notice._0} isError={k.notice.isError} />;
  if ("approval" in k) return <ApprovalRow {...k.approval} onApprove={onApprove} onReject={onReject} />;
  return null;
}

/** Lo de la IA: texto plano a todo el ancho, con markdown. */
function AssistantText({ text }: { text: string }) {
  const html = useMemo(() => renderMarkdown(text), [text]);
  return (
    <div
      className={s.assistant}
      dangerouslySetInnerHTML={{ __html: html }}
      onClick={(e) => {
        const a = (e.target as HTMLElement).closest("a");
        if (!a) return;
        e.preventDefault();
        const href = a.getAttribute("href");
        if (href) void openUrl(href).catch(() => {});
      }}
    />
  );
}

/** Las acciones de la IA, discretas: una fila que se despliega si trae detalle. */
function ActionRow({ title, detail, running, failed }: { title: string; detail: string; running: boolean; failed: boolean }) {
  const [open, setOpen] = useState(failed);
  useEffect(() => {
    if (failed) setOpen(true);
  }, [failed]);
  const expandable = !!detail;
  return (
    <div className={s.action} data-failed={failed}>
      <button type="button" className={s.actionHead} disabled={!expandable} onClick={() => setOpen(!open)}>
        <span className={s.actionMark}>
          {running ? <Spinner size={12} /> : expandable ? <Icon name={open ? "chevronDown" : "chevron"} size={12} /> : "›"}
        </span>
        <span className={s.actionTitle}>{title}</span>
      </button>
      {expandable && open && <div className={s.actionDetail}>{detail}</div>}
    </div>
  );
}

/** Las fotos seguidas (lo que la IA miró en un paso) van juntas en un solo renglón. */
function groupPhotos(items: ChatItem[]): (ChatItem | { id: string; photos: string[] })[] {
  const out: (ChatItem | { id: string; photos: string[] })[] = [];
  for (const item of items) {
    const prev = out[out.length - 1];
    if ("image" in item.kind) {
      if (prev && "photos" in prev) prev.photos.push(item.kind.image._0);
      else out.push({ id: item.id, photos: [item.kind.image._0] });
    } else {
      out.push(item);
    }
  }
  return out;
}

/** Lo que la IA miró, discreto: cerrado muestra cuántas fotos; abierto, miniaturas que se agrandan con un clic. */
function PhotoStrip({ photos }: { photos: string[] }) {
  const [open, setOpen] = useState(false);
  const [zoom, setZoom] = useState<number | null>(null);
  return (
    <div className={s.photos}>
      <button type="button" className={s.photosHead} onClick={() => setOpen(!open)} aria-expanded={open}>
        <Icon name="camera" size={12} />
        <span>{photos.length === 1 ? "1 photo" : `${photos.length} photos`}</span>
        <Icon name={open ? "chevronDown" : "chevron"} size={11} />
      </button>
      {open && (
        <div className={s.thumbs}>
          {photos.map((jpeg, i) => (
            <button key={i} type="button" className={s.thumb} onClick={() => setZoom(i)} aria-label="Enlarge photo">
              <img src={jpegDataURL(jpeg)} alt="What the AI looked at" />
            </button>
          ))}
        </div>
      )}
      {zoom != null && (
        <Dialog title={`Photo ${zoom + 1} of ${photos.length}`} onClose={() => setZoom(null)} width={820}>
          <img className={s.imageLarge} src={jpegDataURL(photos[zoom])} alt="What the AI looked at" />
        </Dialog>
      )}
    </div>
  );
}

function NoticeRow({ text, isError }: { text: string; isError: boolean }) {
  return isError ? (
    <div className={s.errorNotice}>
      <Icon name="warning" size={13} />
      <span>{text}</span>
    </div>
  ) : (
    <div className={s.notice}>{text}</div>
  );
}

/** Un movimiento del robot real que propone la IA: el comando exacto y la decisión de la persona. */
function ApprovalRow({ title, detail, state, onApprove, onReject }: {
  title: string;
  detail: string;
  state: ApprovalState;
  onApprove: () => void;
  onReject: () => void;
}) {
  return (
    <div className={s.approval} data-state={state}>
      <div className={s.approvalHead}>
        <Icon name="hand" size={14} />
        <span className={s.approvalTitle}>{title}</span>
        {state === "approved" && <span className={s.approvalState}>Approved</span>}
        {state === "rejected" && <span className={s.approvalState}>Not approved</span>}
      </div>
      {detail && <div className={s.approvalDetail}>{detail}</div>}
      {state === "pending" && (
        <div className={s.approvalActions}>
          <Button variant="ghost" size="small" onClick={onReject}>
            Reject
          </Button>
          <Button variant="primary" size="small" onClick={onApprove}>
            Approve
          </Button>
        </div>
      )}
    </div>
  );
}

/** «Thinking…» con un brillo que lo recorre de izquierda a derecha. */
function ThinkingRow() {
  return (
    <div className={s.thinking} aria-label="Thinking">
      Thinking…
    </div>
  );
}

// ---------- Compositor ----------

/** El campo para escribirle al robot: caja redondeada, texto que crece y el botón de enviar. */
function ChatComposer({ isRunning, enabled, robotName, onSend, onStop }: {
  isRunning: boolean;
  enabled: boolean;
  robotName: string;
  onSend: (text: string) => void;
  onStop: () => void;
}) {
  const [draft, setDraft] = useState("");
  const field = useRef<HTMLTextAreaElement>(null);
  const canSend = enabled && draft.trim().length > 0;

  // Crece con el texto, hasta un tope (después, scroll).
  useLayoutEffect(() => {
    const el = field.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 200)}px`;
  }, [draft]);

  const send = () => {
    if (!canSend || isRunning) return;
    onSend(draft);
    setDraft("");
  };

  return (
    <div className={s.composerWrap}>
      <div className={cx(s.composer, !enabled && s.composerDisabled)} onMouseDown={(e) => {
        if (e.target === e.currentTarget) {
          e.preventDefault();
          field.current?.focus();
        }
      }}>
        <textarea
          ref={field}
          className={s.field}
          rows={1}
          value={draft}
          disabled={!enabled}
          placeholder={enabled ? `Ask ${robotName} anything` : "Add your API key to get started"}
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
              e.preventDefault();
              send();
            } else if (e.key === "Escape" && isRunning) {
              e.preventDefault();
              onStop();
            }
          }}
        />
        <div className={s.composerBar}>
          <span />
          <button
            type="button"
            className={s.send}
            data-active={canSend || isRunning}
            disabled={!isRunning && !canSend}
            onClick={isRunning ? onStop : send}
            title={isRunning ? "Stop (Esc)" : "Send (Enter)"}
            aria-label={isRunning ? "Stop" : "Send"}
          >
            <Icon name={isRunning ? "stop" : "send"} size={isRunning ? 12 : 15} strokeWidth={2.25} fill={isRunning} />
          </button>
        </div>
      </div>
    </div>
  );
}

// ---------- Markdown ----------

const escapeHtml = (t: string) =>
  t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

/** Markdown sin HTML crudo (se muestra escapado) y solo con enlaces web. */
const markdown = new Marked({
  gfm: true,
  breaks: true,
  renderer: {
    html({ text }: Tokens.HTML | Tokens.Tag) {
      return escapeHtml(text);
    },
    link({ href, title, tokens }: Tokens.Link) {
      const text = this.parser.parseInline(tokens);
      if (!/^(https?:|mailto:)/i.test(href)) return text;
      const t = title ? ` title="${escapeHtml(title)}"` : "";
      return `<a href="${escapeHtml(href)}"${t}>${text}</a>`;
    },
    image({ text }: Tokens.Image) {
      return escapeHtml(text);
    },
  },
});

function renderMarkdown(text: string): string {
  try {
    return markdown.parse(text, { async: false }) as string;
  } catch {
    return escapeHtml(text);
  }
}
