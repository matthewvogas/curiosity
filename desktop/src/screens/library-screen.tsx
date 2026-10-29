import { useEffect } from "react";
import { observer } from "mobx-react-lite";
import { useStores } from "@/app/stores";
import { Workspace, Pane } from "@/components/app-shell";
import { LibraryCard } from "@/components/library-card";
import { Callout, EmptyState, Icon, Spinner, Tabs, TextInput } from "@/components/ui";
import type { LibraryRobot } from "@/types/library-types";
import s from "./library-screen.module.css";

const ALL = "__all__";

/** Biblioteca de MuJoCo Menagerie: robots listos para simular, con un clic. */
export const LibraryScreen = observer(function LibraryScreen() {
  const { library } = useStores();

  useEffect(() => {
    library.beginVisit();
    if (!library.catalog) void library.load();
  }, [library]);

  const catalog = library.catalog;
  const total = catalog?.robots.length ?? 0;
  const count = (c: string) => catalog?.robots.filter((r: LibraryRobot) => r.category === c).length ?? 0;
  const tabs = [{ id: ALL, title: "All", count: total }, ...library.categories.map((c: string) => ({ id: c, title: c, count: count(c) }))];

  return (
    <Workspace>
      <Pane
        title="Robot library"
        captionSafe
        actions={
          <div className={s.search}>
            <Icon name="search" size={14} className={s.searchIcon} />
            <TextInput
              className={s.searchInput}
              placeholder="Search robots"
              value={library.search}
              onChange={(e) => library.setSearch(e.target.value)}
              onKeyDown={(e) => e.key === "Escape" && library.setSearch("")}
            />
          </div>
        }
        bodyClassName={s.body}
      >
        <div className={s.toolbar}>
          <div className={s.subtitle}>{total} robots from MuJoCo Menagerie</div>
          <div className={s.filters}>
            <Tabs tabs={tabs} value={library.category ?? ALL} onChange={(id) => library.setCategory(id === ALL ? null : id)} />
          </div>
          {library.error && (
            <Callout tone="red" icon="warning">
              {library.error}
            </Callout>
          )}
        </div>

        {!catalog ? (
          library.error ? null : (
            <div className={s.loading}>
              <Spinner size={16} />
            </div>
          )
        ) : library.visible.length === 0 ? (
          <EmptyState icon="search" title="No robots found" detail="Try another name or category." />
        ) : (
          <div className={s.grid}>
            {library.visible.map((robot: LibraryRobot) => (
              <LibraryCard
                key={robot.id}
                name={robot.name}
                category={robot.category}
                imageURL={library.imageURL(robot)}
                added={library.isAdded(robot)}
                progress={library.downloading[robot.id] ?? null}
                onAdd={() => void library.add(robot)}
              />
            ))}
          </div>
        )}
      </Pane>
    </Workspace>
  );
});
