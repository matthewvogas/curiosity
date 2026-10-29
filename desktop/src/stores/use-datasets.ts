import { makeAutoObservable, runInAction } from "mobx";
import { HubQueries } from "@/queries/hub-queries";
import { AppPaths } from "@/utils/app-paths";
import type { UseLeRobot } from "@/stores/use-lerobot";
import type { UseSettings } from "@/stores/use-settings";
import type { DatasetInfo, HubDataset } from "@/types/lerobot-types";

const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** Datasets: los de esta computadora (grabados en la app y bajados del Hub) y la búsqueda en Hugging Face. */
export class UseDatasets {
  local: DatasetInfo[] = [];
  hub: HubDataset[] = [];
  query = "so101";
  searching = false;
  loading = false;
  message: string | null = null;

  constructor(private lerobot: UseLeRobot, private settings: UseSettings) {
    makeAutoObservable<UseDatasets, "lerobot" | "settings">(this, { lerobot: false, settings: false });
  }

  setQuery(q: string) {
    this.query = q;
  }

  async load() {
    this.loading = true;
    try {
      const raw: Array<Record<string, any>> = await this.lerobot.datasets([AppPaths.datasets, AppPaths.hubCache]);
      const local = raw
        .map(
          (d): DatasetInfo => ({
            name: typeof d.name === "string" ? d.name : "",
            root: typeof d.root === "string" ? d.root : "",
            source: typeof d.source === "string" ? d.source : "local",
            episodes: Number(d.episodes ?? 0) || 0,
            frames: Number(d.frames ?? 0) || 0,
            fps: typeof d.fps === "number" ? d.fps : null,
            tasks: Array.isArray(d.tasks) ? d.tasks : [],
            bytes: Number(d.bytes ?? 0) || 0,
            cameras: Array.isArray(d.cameras) ? d.cameras : [],
          }),
        )
        .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      runInAction(() => (this.local = local));
    } catch (e) {
      runInAction(() => (this.message = errorText(e)));
    } finally {
      runInAction(() => (this.loading = false));
    }
  }

  async search() {
    this.searching = true;
    try {
      const hub = await HubQueries.searchDatasets(this.query, this.settings.hubToken);
      runInAction(() => {
        this.hub = hub;
        this.message = hub.length === 0 ? `Nothing for “${this.query}” on the Hub.` : null;
      });
    } catch (e) {
      runInAction(() => (this.message = errorText(e)));
    } finally {
      runInAction(() => (this.searching = false));
    }
  }

  async delete(d: DatasetInfo) {
    try {
      await this.lerobot.request("delete_dataset", { root: d.root });
      await this.load();
    } catch (e) {
      runInAction(() => (this.message = errorText(e)));
    }
  }
}
