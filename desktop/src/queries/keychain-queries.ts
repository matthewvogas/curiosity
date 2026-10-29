import { invoke } from "./native";

/** Las API keys viven en el almacén seguro del sistema (Llavero / Administrador de credenciales), nunca en archivos. */
export const KeychainQueries = {
  read: (account: string) => invoke<string | null>("secret_get", { account }),
  save: (account: string, value: string) => invoke<void>("secret_set", { account, value }),
  delete: (account: string) => invoke<void>("secret_delete", { account }),
};
