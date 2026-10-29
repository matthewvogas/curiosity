import type { CameraInfo } from "@/types/lerobot-types";

/**
 * Las cámaras conectadas, como las ve el sistema. El número (index) es el orden de la lista, que en la
 * mayoría de los equipos coincide con el de OpenCV; por eso los robots recuerdan la cámara también por
 * su nombre (Device.cameraName), que es lo que se usa para reconocerla.
 */
export const CameraQueries = {
  async list(): Promise<CameraInfo[]> {
    if (!navigator.mediaDevices?.enumerateDevices) return [];
    const devices = (await navigator.mediaDevices.enumerateDevices()).filter((d) => d.kind === "videoinput");
    return devices.map((d, index) => {
      const name = d.label || `Camera ${index + 1}`;
      // Las integradas y las del teléfono (Continuidad) no son la del robot.
      const external = !/facetime|built-in|integrated|iphone|continuity|desk view/i.test(name);
      return { index, name, external };
    });
  },

  /** Llama a `onChange` cada vez que se conecta o desconecta una cámara. Devuelve cómo dejar de escuchar. */
  observe(onChange: () => void): () => void {
    navigator.mediaDevices?.addEventListener("devicechange", onChange);
    return () => navigator.mediaDevices?.removeEventListener("devicechange", onChange);
  },
};
