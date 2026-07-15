import { useEffect, useMemo, useState } from "react";
import { type Item, type LoginResult, listFavorites, posterUrl } from "../lib/api";
import Poster from "../components/Poster";
// 视图切换图标复用媒体库那套(icons.tsx 没有网格/列表图标且不许改,不重画一遍)。
// 顺带把 LibraryPage.css 显式带进来:收藏页复用 .lib-ddwrap/.lib-dd/.lib-list/.lib-row —— 草稿说收藏页「和媒体库同款」。
import { IconGrid, IconRows } from "./LibraryPage";
import "./LibraryPage.css";
import { IconChevronDown, IconChevronRight, IconPlay } from "../app/icons";

type Props = {
  session: LoginResult;
  onOpenItem: (it: Item) => void;
};

/* 本地排序档位(不需要后端)。"收藏时间" = listFavorites 服务端返回顺序 ——
   Item 上没有收藏时间戳字段,所以只认服务端顺序,不伪造时间(和媒体库 "加入时间" 一个口径)。 */
const SORTS = [
  { id: "fav", label: "收藏时间" },
  { id: "name-asc", label: "名称 A→Z" },
  { id: "name-desc", label: "名称 Z→A" },
] as const;
type SortId = (typeof SORTS)[number]["id"];

/** 收藏页(草稿 PAGE 10):和媒体库同款密集海报网格。
    卡片只有一个操作:单击 = 进详情 —— 用户 2026-07-15 定,覆盖草稿标注 36(悬停 ♥/▶ 和右键菜单都不做),别照草稿"复原"回来。 */
export default function FavoritesPage({ session, onOpenItem }: Props) {
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [sort, setSort] = useState<SortId>("fav");
  const [openDD, setOpenDD] = useState(false);
  const [layout, setLayout] = useState<"grid" | "list">("grid");

  useEffect(() => {
    let alive = true;
    setItems(null);
    setErr("");
    listFavorites()
      .then((x) => alive && setItems(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [session.server]);

  const shown = useMemo(() => {
    if (!items) return [];
    if (sort === "name-asc") return [...items].sort((a, b) => a.name.localeCompare(b.name, "zh"));
    if (sort === "name-desc") return [...items].sort((a, b) => b.name.localeCompare(a.name, "zh"));
    return items; // "fav" = 服务端返回顺序
  }, [items, sort]);

  const sortLabel = SORTS.find((s) => s.id === sort)!.label;

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>收藏</b>
          {items && <span className="count">· {items.length}</span>}
        </span>
        <span className="push">
          {/* 排序(锚定下拉,纯本地排,不需要后端) */}
          <span className="lib-ddwrap">
            <button className="pill" title="排序方式" onClick={() => setOpenDD((d) => !d)}>
              排序 · {sortLabel} <IconChevronDown size={12} />
            </button>
            {openDD && (
              <div className="dd lib-dd">
                {SORTS.map((s) => (
                  <div
                    key={s.id}
                    className={`li${sort === s.id ? " on" : ""}`}
                    onClick={() => {
                      setSort(s.id);
                      setOpenDD(false);
                    }}
                  >
                    <span className="rad" />
                    {s.label}
                  </div>
                ))}
              </div>
            )}
          </span>

          {/* 网格/列表切换(和媒体库同款) */}
          <button
            className="ibtn"
            title={layout === "grid" ? "切换列表" : "切换网格"}
            onClick={() => setLayout((l) => (l === "grid" ? "list" : "grid"))}
          >
            {layout === "grid" ? <IconRows /> : <IconGrid />}
          </button>
        </span>
      </div>

      {openDD && <div className="lib-ddscrim" onClick={() => setOpenDD(false)} />}

      <div className="scroll">
        {err && <div className="empty">加载失败：{err}</div>}
        {items == null ? (
          <div className="dense-grid">
            {Array.from({ length: 14 }).map((_, i) => (
              <div className="pitem" key={i}>
                <div className="pcard poster-ar skeleton" />
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="empty">还没有收藏。在详情页点收藏即可加入。</div>
        ) : layout === "grid" ? (
          <div className="dense-grid">
            {/* 卡片只有一个操作:点 = 进详情。无悬停按钮、无右键(用户 2026-07-15 定,覆盖草稿 36)。 */}
            {shown.map((it, i) => (
              <Poster key={it.id} item={it} session={session} index={i} onOpen={onOpenItem} />
            ))}
          </div>
        ) : (
          <div className="lib-list">
            {shown.map((it) => (
              <button className="lib-row enter" key={it.id} onClick={() => onOpenItem(it)}>
                <span className="lib-row-thumb">
                  {it.has_primary ? (
                    <img src={posterUrl(session, it.id, 120)} loading="lazy" />
                  ) : (
                    <IconPlay size={16} />
                  )}
                </span>
                <span className="lib-row-name">{it.name}</span>
                <IconChevronRight size={15} className="lib-row-cv" />
              </button>
            ))}
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>
    </>
  );
}
