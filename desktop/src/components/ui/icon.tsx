import {
  ArrowClockwise, ArrowCounterClockwise, ArrowSquareOut, ArrowUp, ArrowsOutCardinal, BookOpen, BookmarkSimple, Books, Brain, Broadcast, Camera, CameraRotate, CaretDown, CaretRight, ChartLine, ChatCircle, Check, CheckCircle, Circle, CircleDashed, CircleHalf, CircleNotch, ClockCounterClockwise, Copy, Cpu, Crosshair, Cube, Database, DotsThree, Eye, FastForward, FileCode, FilePlus, FileText, FilmStrip, FolderOpen, Gauge, GearSix, Globe, HandGrabbing, House, Info, Key, Layout, Lightning, ListBullets, MagnifyingGlass, Minus, NotePencil, Package, Pause, PencilSimple, Play, Plug, Plus, Question, Record, SidebarSimple, SkipForward, Sparkle, Stack, Stop, TextB, TextH, TextItalic, Timer, Trash, UploadSimple, Usb, VideoCamera, Warning, X, XCircle,
  type Icon as PhosphorIcon,
} from "@phosphor-icons/react";

/** Todos los íconos de la app, en un solo lugar (Phosphor): nada de íconos sueltos por la app. */
const ICONS = {
  robot: Cube,
  home: House,
  add: Plus,
  play: Play,
  pause: Pause,
  step: SkipForward,
  skip: FastForward,
  reset: ArrowCounterClockwise,
  speed: Gauge,
  camera: Camera,
  video: VideoCamera,
  views: CameraRotate,
  send: ArrowUp,
  stop: Stop,
  sparkles: Sparkle,
  key: Key,
  settings: GearSix,
  file: FilePlus,
  code: FileCode,
  folder: FolderOpen,
  link: Plug,
  globe: Globe,
  check: Check,
  checkCircle: CheckCircle,
  warning: Warning,
  eye: Eye,
  move: ArrowsOutCardinal,
  object: Package,
  trash: Trash,
  chat: ChatCircle,
  scene: Stack,
  gauge: Gauge,
  info: Info,
  help: Question,
  chevron: CaretRight,
  chevronDown: CaretDown,
  clear: NotePencil,
  edit: PencilSimple,
  task: CircleDashed,
  taskTraining: CircleHalf,
  taskLearned: CheckCircle,
  dot: Circle,
  dataset: FilmStrip,
  database: Database,
  model: Brain,
  chip: Cpu,
  history: ClockCounterClockwise,
  search: MagnifyingGlass,
  library: Books,
  more: DotsThree,
  close: X,
  minus: Minus,
  copy: Copy,
  upload: UploadSimple,
  timer: Timer,
  bolt: Lightning,
  sidebar: SidebarSimple,
  inspector: SidebarSimple,
  spinner: CircleNotch,
  record: Record,
  hand: HandGrabbing,
  reload: ArrowClockwise,
  focus: Crosshair,
  bookmark: BookmarkSimple,
  external: ArrowSquareOut,
  chart: ChartLine,
  panels: Layout,
  notes: FileText,
  failed: XCircle,
  bold: TextB,
  italic: TextItalic,
  heading: TextH,
  list: ListBullets,
  live: Broadcast,
  book: BookOpen,
  usb: Usb,
} satisfies Record<string, PhosphorIcon>;

export type IconName = keyof typeof ICONS;

/** Phosphor dibuja un poco más chico que otros sets dentro de su caja: se agranda para que se lea igual. */
const SCALE = 1.15;

/**
 * Phosphor no tiene grosor en píxeles sino pesos: el trazo pedido elige el peso más cercano
 * (≤ 1.6 light · ≤ 2.1 regular · más, bold). El de la app es 2 → regular.
 */
const weightFor = (stroke: number) => (stroke <= 1.6 ? "light" : stroke <= 2.1 ? "regular" : "bold");

export function Icon({ name, size = 15, strokeWidth = 2, fill = false, className, style }: {
  name: IconName;
  size?: number;
  strokeWidth?: number;
  /** Relleno (p. ej. el cuadrado de «parar»). */
  fill?: boolean;
  className?: string;
  style?: React.CSSProperties;
}) {
  const C = ICONS[name];
  // El panel derecho usa el mismo dibujo que la barra lateral, en espejo.
  const spin = name === "spinner" ? { animation: "spin 0.9s linear infinite", ...style } : name === "inspector" ? { transform: "scaleX(-1)", ...style } : style;
  return <C size={Math.round(size * SCALE)} weight={fill ? "fill" : weightFor(strokeWidth)} className={className} style={spin} aria-hidden />;
}

/** El logo de Curiosity (cubo y destello), en el color del texto. */
export function Logo({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="200 230 760 700" fill="none" aria-label="Curiosity">
      <g stroke="currentColor" strokeWidth={56} strokeLinecap="round" strokeLinejoin="round">
        <path d="M 785 543 L 785 435 Q 785 417 769 408 L 529 270 Q 512 260 495 270 L 255 408 Q 239 417 239 435 L 239 718 Q 239 737 255 746 L 495 884 Q 512 894 529 884 L 697 787" />
        <path d="M 253 416 L 495 556 Q 512 566 529 556 L 771 416" />
        <path d="M 512 565 L 512 884" />
      </g>
      <path fill="currentColor" d="M 799 550 C 808 550 809 600 841 632 C 873 664 922 664 922 673 C 922 682 873 682 841 714 C 809 746 808 796 799 796 C 790 796 789 746 757 714 C 725 682 676 682 676 673 C 676 664 725 664 757 632 C 789 600 790 550 799 550 Z" />
    </svg>
  );
}
