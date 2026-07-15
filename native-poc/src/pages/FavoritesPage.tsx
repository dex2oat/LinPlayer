import { useEffect, useMemo, useState } from "react";
import { type Item, type LoginResult, listFavorites, posterUrl, setFavorite, setPlayed } from "../lib/api";
import Poster from "../components/Poster";
// 视图切换图标复用媒体库那套(icons.tsx 没有网格/列表图标且不许改,不重画一遍)。
// 顺带把 LibraryPage.css 显式带进来:收藏页复用 .lib-ddwrap/.lib-dd/.lib-list/.lib-row —— 草稿说收藏页「和媒体库同款」。
import { IconGrid, IconRows } from "./LibraryPage";
import "./LibraryPage.css";
import {
  IconCheck,
  IconChevronDown,
  IconChevronRight,
  IconHeart,
  IconInfo,
  IconPlay,
} from "../app/icons";

type Props = {
  session: LoginResult;
  onOpenItem: (it: Item) => void;
  onPlay: (it: Item) => void;
};

/* 本地排序档位(不需要后端)。"收藏时间" = listFavorites 服务端返回顺序 ——
   Item 上没有收藏时间戳字段,所以只认服务端顺序,不伪造时间(和媒体库 "加入时间" 一个口径)。 */
const SORTS = [
  { id: "fav", label: "收藏时间" },
  { id: "name-asc", label: "名称 A→Z" },
  { id: "name-desc", label: "名称 Z→A" },
] as const;
type SortId = (typeof SORTS)[number]["id"];

/** 收藏页(草稿 PAGE 10):和媒体库同款密集海报网格,海报悬停显现 ♥取消收藏 + ▶播放;右键 = 菜单。 */
export default function FavoritesPage({ session, onOpenItem, onPlay }: Props) {
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [sort, setSort] = useState<SortId>("fav");
  const [openDD, setOpenDD] = useState(false);
  const [layout, setLayout] = useState<"grid" | "list">("grid");
  const [ctx, setCtx] = useState<{ x: number; y: number; item: Item } | null>(null);
  const [toast, setToast] = useState("");

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

  // 右键菜单:点空白/滚动/Esc 关掉(和首页/网盘页一个套路)。
  useEffect(() => {
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setCtx(null);
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2600);
    return () => window.clearTimeout(t);
  }, [toast]);

  // 乐观更新:先从本地移除,失败再拉全量对账。
  function toggleFav(it: Item) {
    setItems((cur) => (cur ? cur.filter((x) => x.id !== it.id) : cur));
    setFavorite(it.id, false).catch(() => {
      setToast("取消收藏失败,已重新同步");
      listFavorites()
        .then(setItems)
        .catch(() => {});
    });
  }

  /** 标注 36:标记已看/未看。反显靠 Item.played(服务端给的)→ 改完重拉收藏表。
      收藏表不会因为标记已看而变化,所以这里重拉是纯粹为了拿新的 played 值。 */
  async function markPlayed(it: Item, played: boolean) {
    setCtx(null);
    try {
      await setPlayed(it.id, played);
      setItems(await listFavorites());
    } catch (e) {
      setToast(`标记失败:${e}`);
    }
  }

  const shown = useMemo(() => {
    if (!items) return [];
    if (sort === "name-asc") return [...items].sort((a, b) => a.name.localeCompare(b.name, "zh"));
    if (sort === "name-desc") return [...items].sort((a, b) => b.name.localeCompare(a.name, "zh"));
    return items; // "fav" = 服务端返回顺序
  }, [items, sort]);

  const openCtx = (e: { preventDefault: () => void; clientX: number; clientY: number }, it: Item) => {
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, item: it });
  };

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
            {shown.map((it, i) => (
              <Poster
                key={it.id}
                item={it}
                session={session}
                index={i}
                fav
                onToggleFav={toggleFav}
                onOpen={onOpenItem}
                onPlay={onPlay}
                onContextMenu={openCtx}
              />
            ))}
          </div>
        ) : (
          <div className="lib-list">
            {shown.map((it) => (
              <button
                className="lib-row enter"
                key={it.id}
                onClick={() => onOpenItem(it)}
                onContextMenu={(e) => openCtx(e, it)}
              >
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

      {/* 标注 36:海报右键菜单。 */}
      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {!ctx.item.is_folder && (
            <div
              className="mi"
              onClick={() => {
                onPlay(ctx.item);
                setCtx(null);
              }}
            >
              <IconPlay size={15} /> 播放
            </div>
          )}
          <div
            className="mi"
            onClick={() => {
              onOpenItem(ctx.item);
              setCtx(null);
            }}
          >
            <IconInfo size={15} /> 查看详情
          </div>
          <div className="mi" onClick={() => void markPlayed(ctx.item, !ctx.item.played)}>
            <IconCheck size={15} /> {ctx.item.played ? "标记未看" : "标记已看"}
          </div>
          <div
            className="mi danger"
            onClick={() => {
              toggleFav(ctx.item);
              setCtx(null);
            }}
          >
            <IconHeart size={15} /> 取消收藏
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
