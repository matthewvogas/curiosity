/**
 * Las unidades de LeRobot por articulación: «deg» (grados), «0-100» o «±100», según el motor. Lo que no va en
 * grados se reparte sobre el rango de esa articulación en el modelo 3D (su URDF).
 */
export const JointUnits = {
  toModel(value: number, unit: string, lower?: number | null, upper?: number | null): number | null {
    if (unit === "deg") return (value * Math.PI) / 180;
    if (lower == null || upper == null) return null;
    const fraction = unit === "0-100" ? value / 100 : (value + 100) / 200;
    return lower + fraction * (upper - lower);
  },

  fromModel(q: number, unit: string, lower?: number | null, upper?: number | null): number | null {
    if (unit === "deg") return (q * 180) / Math.PI;
    if (lower == null || upper == null || !(upper > lower)) return null;
    const fraction = (q - lower) / (upper - lower);
    return unit === "0-100" ? fraction * 100 : fraction * 200 - 100;
  },

  /** Un valor con su unidad, para mostrar. */
  format(value: number, unit?: string | null): string {
    return unit === "deg" ? `${Math.round(value)}°` : `${Math.round(value)}`;
  },
};
