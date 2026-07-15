import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  type Item,
  type LoginResult,
  backdropUrl,
  fmtTime,
  listFavorites,
  listLatest,
  listRandom,
  listResume,
  posterUrl,
  setFavorite,
  thumbUrl,
  views,
} from "../lib/api";
import Poster from "../components/Poster";
import {
  IconChevronLeft,
  IconChevronRight,
  IconClose,
  IconHeart,
  IconInfo,
  IconLibrary,
  IconPlay,
  IconPlus,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./HomePage.css";

type Props = {
  session: LoginResult;
  onOpenLibrary: (view: Item) => void;
  onOpenItem: (it: Item) => void;
  onPlay: (it: Item) => void;
  onSearch: () => void;
  onRefresh: () => void;
  reloadKey: number;
};

/**
 * 横向轨道:草稿末条注「轨道右端悬停显现翻页箭头 ›,滚轮横向滚动;不用移动端的惯性滑动」。
 * 三种轨道(继续观看/媒体库/最新)共用一套滚动+箭头逻辑,不各写一遍。
 */
function Rail({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [edge, setEdge] = useState({ left: false, right: false });

  // 到头的方向不留死箭头,所以要跟着滚动位置算。
  const sync = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    setEdge({
      left: el.scrollLeft > 4,
      right: el.scrollLeft + el.clientWidth < el.scrollWidth - 4,
    });
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    sync();

    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
      // 该方向已经到头就把滚轮还给页面,否则鼠标停在轨道上整页都滚不动了。
      const canScroll =
        e.deltaY > 0
          ? el.scrollLeft + el.clientWidth < el.scrollWidth - 1
          : el.scrollLeft > 1;
      if (!canScroll) return;
      // React 的 onWheel 挂在 root 上且是 passive 的,preventDefault 不生效 →
      // 必须原生非 passive 绑定,不然横向滚的同时整页也跟着纵向滚。
      e.preventDefault();
      el.scrollLeft += e.deltaY;
    };
    el.addEventListener("wheel", onWheel, { passive: false });

    // 数据/图片异步到货会改 scrollWidth,重算箭头显隐。
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    for (const c of Array.from(el.children)) ro.observe(c);

    return () => {
      el.removeEventListener("wheel", onWheel);
      ro.disconnect();
    };
  }, [sync, children]);

  const page = (dir: 1 | -1) => {
    const el = ref.current;
    if (el) el.scrollBy({ left: dir * el.clientWidth * 0.9, behavior: "smooth" });
  };

  return (
    <div className="hm-rail">
      <div className="rail" ref={ref} onScroll={sync}>
        {children}
      </div>
      {edge.left && (
        <button className="hm-arrow left" title="上一屏" onClick={() => page(-1)}>
          <IconChevronLeft size={16} />
        </button>
      )}
      {edge.right && (
        <button className="hm-arrow right" title="下一屏" onClick={() => page(1)}>
          <IconChevronRight size={16} />
        </button>
      )}
    </div>
  );
}

const typeLabel = (t: string) => (t === "Movie" ? "电影" : t === "Series" ? "剧集" : t);

export default function HomePage({
  session,
  onOpenLibrary,
  onOpenItem,
  onPlay,
  onSearch,
  onRefresh,
  reloadKey,
}: Props) {
  const [libs, setLibs] = useState<Item[]>([]);
  const [byLib, setByLib] = useState<Record<string, Item[]>>({});
  const [resume, setResume] = useState<Item[]>([]);
  const [featured, setFeatured] = useState<Item[]>([]);
  const [favIds, setFavIds] = useState<Set<string>>(new Set());
  const [heroIdx, setHeroIdx] = useState(0);
  const [ctx, setCtx] = useState<{ x: number; y: number; item: Item } | null>(null);
  const [toast, setToast] = useState("");
  const [err, setErr] = useState("");
  const hover = useRef(false);

  useEffect(() => {
    let alive = true;
    setByLib({});
    setFeatured([]);
    setHeroIdx(0);
    (async () => {
      try {
        // Hero 走 list_random(服务端 SortBy=Random 且只回有剧照的),不再拿继续观看凑数。
        const [vs, rz, rnd, favs] = await Promise.all([
          views(),
          listResume(12).catch(() => [] as Item[]),
          listRandom(5).catch(() => [] as Item[]),
          listFavorites().catch(() => [] as Item[]),
        ]);
        if (!alive) return;
        setLibs(vs);
        setResume(rz);
        setFeatured(rnd);
        // 心形要显真状态,不能一律画成未收藏。
        setFavIds(new Set(favs.map((f) => f.id)));
        for (const v of vs) {
          const items = await listLatest(v.id, 20).catch(() => [] as Item[]);
          if (!alive) return;
          setByLib((m) => ({ ...m, [v.id]: items }));
        }
      } catch (e) {
        if (alive) setErr(String(e));
      }
    })();
    return () => {
      alive = false;
    };
  }, [session.server, reloadKey]);

  // Hero 自动轮播(标注 6:悬停暂停)。
  useEffect(() => {
    if (featured.length < 2) return;
    const t = window.setInterval(() => {
      if (!hover.current) setHeroIdx((i) => (i + 1) % featured.length);
    }, 6000);
    return () => window.clearInterval(t);
  }, [featured.length]);

  // 右键菜单:点空白/滚动/Esc 关掉(和 NetdiskPage/ServersPage 一个套路)。
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

  const toggleFav = useCallback((it: Item) => {
    setFavIds((s) => {
      const next = !s.has(it.id);
      setFavorite(it.id, next).catch((e) => {
        // 后端没落地就把 UI 状态退回去,不留假的红心。
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
  }, []);

  const hero = featured[heroIdx];
  const step = (d: 1 | -1) =>
    setHeroIdx((i) => (i + d + featured.length) % featured.length);
  // Item 里只有类型/时长是实的(年份/简介在 ItemDetail,首页不为 5 张 Hero 各拉一次详情)。
  const heroMeta = hero
    ? [typeLabel(hero.type_), hero.runtime_secs > 0 ? fmtTime(hero.runtime_secs) : ""]
        .filter(Boolean)
        .join(" · ")
    : "";

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>首页</b>
        </span>
        <span className="push">
          <button className="searchbox" onClick={onSearch}>
            <IconSearch size={14} /> 搜索 / 聚合… <span className="kbd">Ctrl K</span>
          </button>
          <button className="ibtn" title="刷新" onClick={onRefresh}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll">
        {err && <div className="empty">加载失败：{err}</div>}

        {hero && (
          <div
            className="hero hm-hero"
            onMouseEnter={() => (hover.current = true)}
            onMouseLeave={() => (hover.current = false)}
            onClick={() => onOpenItem(hero)}
          >
            <img
              key={hero.id}
              className="hero-bg"
              src={backdropUrl(session, hero.id)}
              onError={(e) => {
                const el = e.target as HTMLImageElement;
                // list_random 保证有 backdrop,但取图仍可能失败 → 退回海报。
                if (hero.has_primary) el.src = posterUrl(session, hero.id, 720);
                else el.style.opacity = "0";
              }}
            />
            <div className="hero-grad" />

            {featured.length > 1 && (
              <>
                <button
                  className="hm-hot left"
                  title="上一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(-1);
                  }}
                >
                  <IconChevronLeft size={22} />
                </button>
                <button
                  className="hm-hot right"
                  title="下一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(1);
                  }}
                >
                  <IconChevronRight size={22} />
                </button>
              </>
            )}

            <div className="hero-body">
              <div className="hero-eyebrow">随机推荐</div>
              <div className="hero-title">{hero.name}</div>
              {heroMeta && <div className="hero-meta">{heroMeta}</div>}
              <div className="hero-cta">
                <button
                  className="btn primary big"
                  onClick={(e) => {
                    e.stopPropagation();
                    onPlay(hero);
                  }}
                >
                  <IconPlay size={16} /> 播放
                </button>
                <button
                  className={`hero-ghost${favIds.has(hero.id) ? " on" : ""}`}
                  title={favIds.has(hero.id) ? "取消收藏" : "收藏"}
                  onClick={(e) => {
                    e.stopPropagation();
                    toggleFav(hero);
                  }}
                >
                  <IconPlus size={17} />
                </button>
                <button
                  className="hero-ghost"
                  title="详情"
                  onClick={(e) => {
                    e.stopPropagation();
                    onOpenItem(hero);
                  }}
                >
                  <IconInfo size={17} />
                </button>
              </div>
            </div>

            <div className="hero-dots">
              {featured.map((f, i) => (
                <i
                  key={f.id}
                  className={i === heroIdx ? "on" : ""}
                  onClick={(e) => {
                    e.stopPropagation();
                    setHeroIdx(i);
                  }}
                />
              ))}
            </div>
          </div>
        )}

        <div className="hm-body">
          {resume.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">继续观看</span>
              </div>
              {/* 继续观看基本都是剧集,封面本来就是 16:9 剧照 → thumb 横版,不用竖海报。 */}
              <Rail>
                {resume.map((it, i) => (
                  <div
                    className="r-wide"
                    key={it.id}
                    onContextMenu={(e) => {
                      e.preventDefault();
                      setCtx({ x: e.clientX, y: e.clientY, item: it });
                    }}
                  >
                    <Poster
                      item={it}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      onPlay={onPlay}
                      fav={favIds.has(it.id)}
                      onToggleFav={toggleFav}
                      index={i}
                    />
                  </div>
                ))}
              </Rail>
            </section>
          )}

          {libs.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">媒体库</span>
              </div>
              <Rail>
                {libs.map((v) => (
                  <button
                    className="r-wide hm-lib"
                    key={v.id}
                    title={v.name}
                    onClick={() => onOpenLibrary(v)}
                  >
                    <div className="hm-libimg">
                      {v.has_primary ? (
                        <img
                          src={thumbUrl(session, v.id)}
                          loading="lazy"
                          onError={(e) =>
                            ((e.target as HTMLImageElement).style.visibility = "hidden")
                          }
                        />
                      ) : (
                        <div className="hm-libfb">
                          <IconLibrary size={26} />
                        </div>
                      )}
                    </div>
                    <div className="pcap">{v.name}</div>
                  </button>
                ))}
              </Rail>
            </section>
          )}

          {libs.map((lib) => {
            const items = byLib[lib.id];
            return (
              <section key={lib.id}>
                <div className="rowlab">
                  <span className="h">最新 · {lib.name}</span>
                  <button className="all" onClick={() => onOpenLibrary(lib)}>
                    查看更多 <IconChevronRight size={12} />
                  </button>
                </div>
                {items == null ? (
                  <div className="rail">
                    {Array.from({ length: 7 }).map((_, i) => (
                      <div className="r-poster" key={i}>
                        <div className="pcard poster-ar skeleton" />
                      </div>
                    ))}
                  </div>
                ) : items.length === 0 ? (
                  <div className="empty">这个库还没有内容</div>
                ) : (
                  <Rail>
                    {items.map((it, i) => (
                      <div className="r-poster" key={it.id}>
                        <Poster
                          item={it}
                          session={session}
                          onOpen={onOpenItem}
                          onPlay={onPlay}
                          fav={favIds.has(it.id)}
                          onToggleFav={toggleFav}
                          index={i}
                        />
                      </div>
                    ))}
                  </Rail>
                )}
              </section>
            );
          })}
          <div style={{ height: 40 }} />
        </div>
      </div>

      {/* 标注 7:海报卡右键菜单。 */}
      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          <div
            className="mi"
            onClick={() => {
              setToast("「移出继续观看」后端待接");
              setCtx(null);
            }}
          >
            <IconClose size={15} /> 移出继续观看
          </div>
          <div
            className="mi"
            onClick={() => {
              setToast("「标记已看」后端待接");
              setCtx(null);
            }}
          >
            <IconPlay size={15} /> 标记已看
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
