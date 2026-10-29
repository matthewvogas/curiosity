/**
 * El «cerebro del brazo» con el robot real: el mismo ejecutor del simulador (skills.js), corriendo sobre el
 * gemelo 3D con los límites de la calibración. Planifica la trayectoria entera y el robot la hace de una vez;
 * la IA solo dice qué (un píxel en una cámara calibrada) y aprueba una vez por acción.
 *
 * Calibrar una cámara: la pinza va sola a varios puntos (cada uno con un clic de la persona en «Move») y la
 * persona marca en la imagen dónde se ve la punta; con eso se sabe dónde está la cámara (ver CameraCalibration).
 *
 * Los métodos (calibration, startCalibration, runArmSkill, tablePoint…) están en UseLiveRobot; aquí, sus
 * constantes y problemas.
 */
export const LiveArm = {
  /** Velocidad de las articulaciones al planificar (rad/s): por debajo del límite del puente (40°/s). */
  armSpeed: 0.55,
  /** Por debajo de este porcentaje de su recorrido la pinza se cerró del todo: no agarró nada. */
  emptyGrip: 4.0,
  /** Puntos para calibrar (m, marco de la base): repartidos en ancho, fondo y alto, delante del robot. */
  calibrationPoints: [
    [0.16, -0.08, 0.03], [0.26, 0.08, 0.03], [0.26, -0.08, 0.11], [0.16, 0.08, 0.11],
    [0.21, 0.0, 0.06], [0.18, -0.03, 0.15], [0.28, 0.0, 0.05], [0.2, 0.1, 0.08],
  ] as number[][],
};

export type ArmProblem = { kind: "notCalibrated"; camera: string } | { kind: "noPicture"; camera: string } | { kind: "offTable" };

export function armProblemMessage(p: ArmProblem): string {
  switch (p.kind) {
    case "notCalibrated":
      return `The camera "${p.camera}" isn't calibrated. Ask the user to calibrate it in the Arm tab (it takes a minute).`;
    case "noPicture":
      return `Look through "${p.camera}" first (look), then point in that picture.`;
    case "offTable":
      return "That pixel doesn't look at the table.";
  }
}
