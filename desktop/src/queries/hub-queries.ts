import { fetch } from "@tauri-apps/plugin-http";
import type { HubDataset } from "@/types/lerobot-types";

/** El Hub de Hugging Face: buscar datasets de LeRobot. Devuelve los datos crudos de la API. */
export const HubQueries = {
  /** Datasets de LeRobot que coinciden con `query`, los más descargados primero. */
  async searchDatasets(query: string, token: string | null): Promise<HubDataset[]> {
    const params = new URLSearchParams({ search: query, filter: "LeRobot", sort: "downloads", direction: "-1", limit: "40" });
    const res = await fetch(`https://huggingface.co/api/datasets?${params}`, {
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
    if (res.status !== 200) throw new Error("The Hugging Face Hub didn't respond.");
    const list = (await res.json()) as Array<Record<string, any>>;
    return list.filter((d) => typeof d.id === "string").map((d) => ({ id: d.id, downloads: d.downloads ?? 0, likes: d.likes ?? 0 }));
  },
  url: (id: string) => `https://huggingface.co/datasets/${id}`,
};
