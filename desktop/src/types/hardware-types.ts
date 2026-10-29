import type { SwiftDate } from "@/utils/codable";

/** Familias de servos en bus serie: la mayoría de los brazos abiertos (SO-100/101, Koch, LeKiwi, ALOHA…). */
export type BusProtocol = "feetech" | "dynamixel2" | "dynamixel1";

export const BUS_NAMES: Record<BusProtocol, string> = {
  feetech: "Feetech STS / SMS",
  dynamixel2: "Dynamixel (protocol 2.0)",
  dynamixel1: "Dynamixel (protocol 1.0)",
};

/** Un motor que respondió en el bus. */
export type FoundMotor = { id: number; model: number; position?: number | null };

const MODELS: Record<number, string> = {
  777: "STS3215", 2825: "STS3250", 1284: "SCS0009", 12: "AX-12", 29: "MX-28", 1060: "XL430-W250", 1200: "XL330-M288",
  1190: "XL330-M077", 1020: "XM430-W350", 1030: "XM430-W210", 1120: "XM540-W270", 1090: "XH430-V350",
};
export const motorModelName = (m: FoundMotor) => MODELS[m.model] ?? `Model ${m.model}`;

/** Una cámara calibrada: su proyección (3×4, coordenadas de imagen 0…1) y qué tan bien ajustó. */
export type CameraFit = { matrix: number[]; errorPx: number; points: number; date: SwiftDate };

/** Un robot físico conectado por USB (un adaptador serie). Su id es el puerto del follower. */
export type Device = {
  id: string;
  name: string;
  bus: BusProtocol;
  baud: number;
  found: FoundMotor[];
  probedAt?: SwiftDate;
  /** Nombre de la calibración del follower en LeRobot (--robot.id). */
  followerID?: string;
  /** El leader (el brazo que mueves con la mano): su puerto y su calibración (--teleop.id). */
  leaderPort?: string;
  leaderID?: string;
  /** La cámara para grabar y para los modelos (índice de OpenCV) y su nombre, para reconocerla. */
  cameraIndex?: number;
  cameraName?: string;
  /** Otras cámaras (por nombre) que se ven en vivo y que la IA puede mirar, p. ej. una vista desde arriba. */
  extraCameraNames?: string[];
  /** Dónde está cada cámara respecto del robot (la calibración con la pinza), por nombre de cámara. */
  cameraCalibrations?: Record<string, CameraFit>;
  /** El tipo de robot y de leader en LeRobot (--robot.type, --teleop.type). */
  robotType?: string;
  teleopType?: string;
  /** El modelo 3D (de la simulación) que copia al robot en vivo. "" = ninguno. */
  modelID?: string;
};

export const newDevice = (id: string, leaderPort?: string): Device => ({ id, name: "", bus: "feetech", baud: 1_000_000, found: [], leaderPort });

/** Qué parece ser, por los motores que respondieron. */
export function deviceGuess(d: Device): string | null {
  if (d.found.length === 0) return null;
  const models = new Set(d.found.map(motorModelName));
  if (models.size === 1 && models.has("STS3215") && d.found.length === 6) return "SO-101";
  return `${d.found.length} motors`;
}

export const Dev = {
  extraNames: (d: Device) => d.extraCameraNames ?? [],
  /** Lo elegido o, si no se eligió, lo que se deduce de los motores que respondieron. */
  robotKind: (d: Device) => d.robotType ?? (deviceGuess(d) === "SO-101" ? "so101_follower" : null),
  teleopKind: (d: Device) => d.teleopType ?? (deviceGuess(d) === "SO-101" ? "so101_leader" : null),
  model: (d: Device) => d.modelID ?? (deviceGuess(d) === "SO-101" ? "bundled.so101" : null),
  canTeleoperate: (d: Device) => !!(Dev.robotKind(d) && Dev.teleopKind(d) && d.followerID && d.leaderPort && d.leaderID),
  canRecord: (d: Device) => Dev.canTeleoperate(d) && d.cameraIndex != null,
  canRunPolicy: (d: Device) => !!(Dev.robotKind(d) && d.followerID && d.cameraIndex != null),
  displayName: (d: Device) => d.name || deviceGuess(d) || "Robot",
};
