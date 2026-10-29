/**
 * Preferencias chicas (como UserDefaults): modelo elegido, pestaña abierta, robot seleccionado.
 * Nunca secretos: esos van en KeychainQueries.
 */
export const Preferences = {
  get<T>(key: string, fallback: T): T {
    try {
      const raw = localStorage.getItem(key);
      return raw == null ? fallback : (JSON.parse(raw) as T);
    } catch {
      return fallback;
    }
  },
  set(key: string, value: unknown) {
    try {
      if (value === undefined || value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, JSON.stringify(value));
    } catch {
      /* sin almacenamiento: se pierde al cerrar */
    }
  },
};
