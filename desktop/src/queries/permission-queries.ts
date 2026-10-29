import { isMac } from "./native";

/**
 * Permisos del sistema que necesita el robot real. El puente de LeRobot usa la cámara a nombre de la app,
 * así que el permiso se pide aquí, antes de abrirla (en macOS; Windows no lo pide por app).
 */
export const PermissionQueries = {
  /** true si la app puede usar la cámara; la primera vez el sistema le pregunta a la persona. */
  async camera(): Promise<boolean> {
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      stream.getTracks().forEach((t) => t.stop());
      return true;
    } catch {
      return false;
    }
  },

  /** Dónde se cambia el permiso de cámara en el sistema. */
  cameraSettingsURL: () =>
    isMac() ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera" : "ms-settings:privacy-webcam",
};
