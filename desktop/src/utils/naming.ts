/** Nombres de carpeta a partir de texto libre: «Pon el cubo rojo en el vaso» → «pon_el_cubo_rojo_en_el_vaso». */
export const Naming = {
  slug(text: string, max = 40): string {
    const plain = text.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase();
    const parts = plain.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    const slug = parts.join("_").slice(0, max).replace(/^_+|_+$/g, "");
    return slug || "task";
  },

  /** `base`, o `base_2`, `base_3`… si ya existe. */
  unique(base: string, taken: Set<string>): string {
    if (!taken.has(base)) return base;
    let i = 2;
    while (taken.has(`${base}_${i}`)) i++;
    return `${base}_${i}`;
  },
};
