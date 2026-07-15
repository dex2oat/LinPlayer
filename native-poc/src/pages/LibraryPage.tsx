import { useEffect, useMemo, useState } from "react";
import {
  type Item,
  type LoginResult,
  listFavorites,
  listItems,
  posterUrl,
  setFavorite,
  thumbUrl,
  views,
} from "../lib/api";
import Poster from "../components/Poster";
import {
  IconChevronDown,
  IconChevronRight,
  IconHeart,
  IconInfo,
  IconLibrary,
  IconList,
  IconPlay,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./LibraryPage.css";

type Props = {
  session: LoginResult;
  view: Item | null;
  onPickView: (v: Item) => void;
  onBack: () => void;
  onOpenItem: (it: Item) => void;
  onSearch: () => void;
};

/* 本地排序档位(服务端不透传 dateCreated/年份/评分,只做诚实的本地排序)。 */
const SORTS = [
  { id: "added", label: "加入时间" },
  { id: "name-asc", label: "名称 A→Z" },
  { id: "name-desc", label: "名称 Z→A" },
] as const;
type SortId = (typeof SORTS)[number]["id"];

/* Emby type_ → 中文;筛选只按数据里真实存在的类型分面(不造假)。 */
const TYPE_LABEL: Record<string, string> = {
  Movie: "电影",
  Series: "剧集",
  Season: "季",
  Episode: "单集",
  BoxSet: "合集",
  Folder: "文件夹",
  Video: "视频",
  MusicVideo: "MV",
};
const typeName = (t: string) => TYPE_LABEL[t] ?? t;

/* 内联描边网格/列表图标(icons.tsx 里没有且不许改,禁 emoji)。
   收藏页要同一套视图切换图标 → 从这里 export 复用,不重画一遍。 */
export const IconGrid = ({ size = 15 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} aria-hidden>
    <rect x="3" y="3" width="7" height="7" rx="1.4" />
    <rect x="14" y="3" width="7" height="7" rx="1.4" />
    <rect x="3" y="14" width="7" height="7" rx="1.4" />
    <rect x="14" y="14" width="7" height="7" rx="1.4" />
  </svg>
);
export const IconRows = ({ size = 15 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" aria-hidden>
    <path d="M4 6h16M4 12h16M4 18h16" />
  </svg>
);

export default function LibraryPage({ session, view, onPickView, onBack, onOpenItem, onSearch }: Props) {
  const [libs, setLibs] = useState<Item[] | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [reload, setReload] = useState(0);

  const [sort, setSort] = useState<SortId>("added");
  const [filterTypes, setFilterTypes] = useState<Set<string>>(new Set());
  const [openDD, setOpenDD] = useState<null | "sort" | "filter">(null);
  const [layout, setLayout] = useState<"grid" | "list">("grid");
  const [ctx, setCtx] = useState<{ x: number; y: number; item: Item } | null>(null);
  const [toast, setToast] = useState("");
  // Item 上没有收藏标记字段 → 单独拉一次收藏表,右键菜单才能显示「收藏/取消收藏」的真实状态(同首页做法)。
  const [favIds, setFavIds] = useState<Set<string>>(new Set());

  // 切库时清筛选/下拉状态。
  useEffect(() => {
    setFilterTypes(new Set());
    setOpenDD(null);
  }, [view?.id]);

  useEffect(() => {
    let alive = true;
    listFavorites()
      .then((fs) => alive && setFavIds(new Set(fs.map((f) => f.id))))
      .catch(() => {}); // 收藏表拉不到不该拖垮媒体库主流程
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

  const toggleFav = (it: Item) => {
    setFavIds((s) => {
      const next = !s.has(it.id);
      setFavorite(it.id, next).catch((e) => {
        // 后端没落地就把 UI 状态退回去,不留假的收藏态。
        setFavIds((cur) => {
          const back = new Set(cur);
          if (next) back.delete(it.id);
          else back.add(it.id);
          return back;
        });
        setToast(`收藏失败:${e}`);
      });
      const n = new Set(s);
      if (next) n.add(it.id);
      else n.delete(it.id);
      return n;
    });
  };

  const openCtx = (e: { preventDefault: () => void; clientX: number; clientY: number }, it: Item) => {
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, item: it });
  };

  useEffect(() => {
    let alive = true;
    setErr("");
    (async () => {
      try {
        if (view) {
          setItems(null);
          const list = await listItems(view.id);
          if (alive) setItems(list);
        } else {
          setLibs(null);
          const vs = await views();
          if (alive) setLibs(vs);
        }
      } catch (e) {
        if (alive) setErr(String(e));
      }
    })();
    return () => {
      alive = false;
    };
  }, [view?.id, session.server, reload]);

  const types = useMemo(() => {
    const s = new Set<string>();
    items?.forEach((it) => s.add(it.type_));
    return [...s];
  }, [items]);

  const shown = useMemo(() => {
    if (!items) return [];
    let r = filterTypes.size ? items.filter((it) => filterTypes.has(it.type_)) : items;
    if (sort === "name-asc") r = [...r].sort((a, b) => a.name.localeCompare(b.name, "zh"));
    else if (sort === "name-desc") r = [...r].sort((a, b) => b.name.localeCompare(a.name, "zh"));
    return r; // "added" = 服务端返回顺序(诚实,不伪造时间戳)
  }, [items, filterTypes, sort]);

  // ---------------- 库列表(view == null) ----------------
  if (!view) {
    return (
      <>
        <div className="cbar">
          <span className="crumb">
            <b>媒体库</b>
          </span>
          <span className="push">
            <button className="searchbox" onClick={onSearch}>
              <IconSearch size={14} /> 搜索 / 聚合…
            </button>
            <button className="ibtn" title="刷新" onClick={() => setReload((k) => k + 1)}>
              <IconRefresh size={15} />
            </button>
          </span>
        </div>
        <div className="scroll">
          {err && <div className="empty">加载失败：{err}</div>}
          <div className="lib-grid">
            {libs == null
              ? Array.from({ length: 8 }).map((_, i) => (
                  <div className="lib-card" key={i}>
                    <div className="lib-cover skeleton lib-skel" />
                  </div>
                ))
              : libs.map((lib, i) => (
                  <button
                    key={lib.id}
                    type="button"
                    className="lib-card enter"
                    style={{ animationDelay: `${Math.min(i, 10) * 30}ms` }}
                    onClick={() => onPickView(lib)}
                  >
                    <div className="lib-cover">
                      {lib.has_primary ? (
                        <img src={thumbUrl(session, lib.id, 720)} loading="lazy" />
                      ) : (
                        <IconLibrary size={38} />
                      )}
                    </div>
                    <div className="lib-name">{lib.name}</div>
                  </button>
                ))}
          </div>
          {libs != null && libs.length === 0 && !err && <div className="empty">没有可用的媒体库</div>}
          <div style={{ height: 40 }} />
        </div>
      </>
    );
  }

  // ---------------- 库内(view != null) ----------------
  const sortLabel = SORTS.find((s) => s.id === sort)!.label;

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <button className="crumb-btn" onClick={onBack}>
            媒体库
          </button>
          <span className="sep">›</span>
          <b>{view.name}</b>
          {items != null && <span className="count">· {items.length}</span>}
        </span>
        <span className="push">
          <button className="searchbox" onClick={onSearch}>
            <IconSearch size={14} /> 库内搜索…
          </button>

          {/* 排序(锚定下拉) */}
          <span className="lib-ddwrap">
            <button
              className="pill"
              onClick={() => setOpenDD((d) => (d === "sort" ? null : "sort"))}
            >
              排序 · {sortLabel} <IconChevronDown size={13} />
            </button>
            {openDD === "sort" && (
              <div className="dd lib-dd">
                {SORTS.map((s) => (
                  <div
                    key={s.id}
                    className={`li${sort === s.id ? " on" : ""}`}
                    onClick={() => {
                      setSort(s.id);
                      setOpenDD(null);
                    }}
                  >
                    <span className="rad" />
                    {s.label}
                  </div>
                ))}
              </div>
            )}
          </span>

          {/* 筛选(锚定下拉,只列数据里真实存在的类型分面) */}
          <span className="lib-ddwrap">
            <button
              className={`pill${filterTypes.size ? " on" : ""}`}
              onClick={() => setOpenDD((d) => (d === "filter" ? null : "filter"))}
            >
              筛选{filterTypes.size ? ` · ${filterTypes.size}` : ""} <IconChevronDown size={13} />
            </button>
            {openDD === "filter" && (
              <div className="dd lib-dd">
                {types.length <= 1 ? (
                  <div className="lib-dd-note">此库无可筛选的类型分面。年份/标签/评分需服务端分面接口,暂未接。</div>
                ) : (
                  types.map((t) => {
                    const on = filterTypes.has(t);
                    return (
                      <div
                        key={t}
                        className={`li${on ? " on" : ""}`}
                        onClick={() =>
                          setFilterTypes((prev) => {
                            const next = new Set(prev);
                            if (on) next.delete(t);
                            else next.add(t);
                            return next;
                          })
                        }
                      >
                        <span className="rad" />
                        {typeName(t)}
                      </div>
                    );
                  })
                )}
              </div>
            )}
          </span>

          {/* 网格/列表切换 */}
          <button
            className="ibtn"
            title={layout === "grid" ? "切换列表" : "切换网格"}
            onClick={() => setLayout((l) => (l === "grid" ? "list" : "grid"))}
          >
            {layout === "grid" ? <IconRows /> : <IconGrid />}
          </button>
          <button className="ibtn" title="刷新" onClick={() => setReload((k) => k + 1)}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      {openDD && <div className="lib-ddscrim" onClick={() => setOpenDD(null)} />}

      <div className="scroll">
        {/* 已选筛选胶囊行 */}
        {filterTypes.size > 0 && (
          <div className="chipbar" style={{ margin: "2px 18px 6px" }}>
            {[...filterTypes].map((t) => (
              <span className="genre" key={t}>
                类型: {typeName(t)}
                <span
                  className="x"
                  onClick={() =>
                    setFilterTypes((prev) => {
                      const next = new Set(prev);
                      next.delete(t);
                      return next;
                    })
                  }
                >
                  ✕
                </span>
              </span>
            ))}
            <span className="genre" style={{ cursor: "pointer" }} onClick={() => setFilterTypes(new Set())}>
              清除
            </span>
          </div>
        )}

        {err && <div className="empty">加载失败：{err}</div>}

        {items == null ? (
          <div className="dense-grid">
            {Array.from({ length: 14 }).map((_, i) => (
              <div className="pcard poster-ar skeleton" key={i} />
            ))}
          </div>
        ) : shown.length === 0 ? (
          <div className="empty">{items.length === 0 ? "这个库还没有内容" : "没有符合筛选的内容"}</div>
        ) : layout === "grid" ? (
          <div className="dense-grid">
            {shown.map((it, i) => (
              <Poster
                key={it.id}
                item={it}
                session={session}
                onOpen={onOpenItem}
                onPlay={onOpenItem}
                index={i}
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

      {/* 标注 11:海报右键菜单。
          没有「播放」项 —— Shell 没给媒体库传 onPlay(只有 onOpenItem),
          硬塞一个点了只会跳详情的「播放」就又是个假按钮。 */}
      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          <div
            className="mi"
            onClick={() => {
              onOpenItem(ctx.item);
              setCtx(null);
            }}
          >
            <IconInfo size={15} /> 查看详情
          </div>
          <div
            className="mi"
            onClick={() => {
              // 后端没有 markPlayed 命令 → 诚实告知,不给假反馈。
              setToast("「标记已看」后端待接");
              setCtx(null);
            }}
          >
            <IconList size={15} /> 标记已看
          </div>
          <div
            className="mi"
            onClick={() => {
              toggleFav(ctx.item);
              setCtx(null);
            }}
          >
            <IconHeart size={15} /> {favIds.has(ctx.item.id) ? "取消收藏" : "收藏"}
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
