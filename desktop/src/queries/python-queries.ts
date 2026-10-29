import { invoke } from "./native";

/** Dónde está instalado LeRobot en esta computadora (el Python de su entorno), o null. */
export const PythonQueries = {
  findLeRobot: () => invoke<string | null>("find_lerobot"),
};
