/**
 * Conversión entre las unidades del motor (SI: radianes, metros) y las que ve la persona o la IA
 * (grados para giros, centímetros para desplazamientos y posiciones).
 */
export const Units = {
  toDisplay: (value: number, jointType: string) => (jointType === "prismatic" ? value * 100 : (value * 180) / Math.PI),
  fromDisplay: (value: number, jointType: string) => (jointType === "prismatic" ? value / 100 : (value * Math.PI) / 180),
  symbol: (jointType: string) => (jointType === "prismatic" ? "cm" : "°"),

  format(value: number, jointType: string): string {
    const v = Units.toDisplay(value, jointType);
    return jointType === "prismatic" ? `${v.toFixed(1)} cm` : `${v.toFixed(0)}°`;
  },

  centimeters: (meters: number[]) => meters.map((m) => Math.round(m * 1000) / 10),
  meters: (centimeters: number[]) => centimeters.map((c) => c / 100),

  clock(seconds: number): string {
    const s = Math.max(0, Math.floor(seconds));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  },

  /** Una duración larga para leer: «3 h 17 min», «12 min». */
  duration(seconds: number): string {
    const minutes = Math.max(1, Math.round(seconds / 60));
    return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${minutes % 60} min`;
  },

  /** «1:02:03» o «02:03» (como los escribe tqdm) → segundos. */
  seconds(text: string): number | null {
    const raw = text.split(":");
    const parts = raw.map(Number);
    if (parts.some((p) => !Number.isFinite(p)) || parts.length < 2 || parts.length > 3) return null;
    return parts.reduce((acc, p) => acc * 60 + p, 0);
  },
};
