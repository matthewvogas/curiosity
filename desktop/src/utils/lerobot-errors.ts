/** Los errores de LeRobot, dichos de forma que se entienda qué hacer. */
export const LeRobotErrors = {
  friendly(raw: string): string {
    const t = raw.toLowerCase();
    // Los avisos del puente que ya dicen qué hacer se muestran tal cual.
    if (raw.startsWith("This model")) return raw;
    // Un problema leyendo la configuración no es la cámara: se muestra tal cual.
    if (t.includes("failed when parsing") || t.includes("didn't accept the settings")) return `LeRobot didn't accept the settings: ${raw}`;
    if (t.includes("camera") || t.includes("opencv")) {
      return `The camera didn't respond. Check Curiosity's camera permission and make sure no other app is using it. (${raw})`;
    }
    // En Windows, pyserial dice «Access is denied» si otra app tiene el puerto y «could not open port» si no está.
    if (t.includes("busy") || t.includes("resource temporarily") || t.includes("access is denied")) return "The robot's port is being used by another app.";
    if (t.includes("no such file") || t.includes("could not connect") || t.includes("missing motor") || t.includes("could not open port")) {
      return "An arm isn't responding. Check the USB cable and that its power supply is on.";
    }
    if (t.includes("calibrat")) return "The calibration doesn't match the motors. Calibrate again in the terminal.";
    if (t.includes("fileexists") || t.includes("file exists")) return "A folder with that name already exists. Try again.";
    return `LeRobot stopped: ${raw}`;
  },
};
