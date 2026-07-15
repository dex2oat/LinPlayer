import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type MouseEvent,
  type ReactNode,
} from "react";
import {
  type Item,
  type LoginResult,
  backdropUrl,
  fmtTime,
  listCollections,
  listFavorites,
  listLatest,
  listRandom,
  listResume,
  logoUrl,
  posterUrl,
  setFavorite,
  setPlayed,
  thumbUrl,
  views,
} from "../lib/api";
import Poster from "../components/Poster";
import {
  IconCheck,
  IconChevronLeft,
  IconChevronRight,
  IconHeart,
  IconLibrary,
  IconPlay,
  IconPlus,
  IconInfo,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./HomePage.css";

/**
 * Hero 的 logo 标题(标注 6:「大幅剧照 + logo 标题」)。
 * Emby 的 /Items/{id}/Images/Logo 和 posterUrl 同形状,只是 Logo 而非 Primary。
 * 就地放不进 api.ts:那份文件不归这里改,而且目前只有首页 Hero 用得上。
 * ★ 核层 Item 没有 has_logo 之类的标志位 → 只能靠 <img onError> 兜底回文字标题,
 *   没有别的诚实判据(先 HEAD 探一次纯属多一个往返)。
 */


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
  const [collections, setCollections] = useState<Item[]>([]);
  const [featured, setFeatured] = useState<Item[]>([]);
  const [favIds, setFavIds] = useState<Set<string>>(new Set());
  const [heroIdx, setHeroIdx] = useState(0);
  /** 取 Logo 失败的条目 id。按 id 记而不是一个 bool —— 否则翻到下一张 Hero 还顶着上一张的失败态。 */
  const [logoFail, setLogoFail] = useState<Set<string>>(new Set());
  const [ctx, setCtx] = useState<{ x: number; y: number; item: Item } | null>(null);
  const [toast, setToast] = useState("");
  const [err, setErr] = useState("");
  const hover = useRef(false);
  const cbarRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let alive = true;
    setByLib({});
    setFeatured([]);
    setHeroIdx(0);
    setLogoFail(new Set());
    (async () => {
      try {
        // Hero 走 list_random(服务端 SortBy=Random 且只回有剧照的),不再拿继续观看凑数。
        const [vs, rz, rnd, favs, cols] = await Promise.all([
          views(),
          listResume(12).catch(() => [] as Item[]),
          listRandom(5).catch(() => [] as Item[]),
          listFavorites().catch(() => [] as Item[]),
          // 合集轨道(草稿 L643-649)。没有合集的服务器就是空数组,不是错误 → 静默空。
          listCollections().catch(() => [] as Item[]),
        ]);
        if (!alive) return;
        setLibs(vs);
        setResume(rz);
        setFeatured(rnd);
        setCollections(cols);
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

  const openCtx = useCallback((e: MouseEvent, it: Item) => {
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, item: it });
  }, []);

  /** 右键「标记为已/未播放」。
   * ★ Emby 没有「从继续观看里删掉」这种端点 —— 继续观看就是 Resume 查询的结果,
   *   标记已播放它自己就掉出去,标记未播放又可能回来。所以标记完只需重拉这条轨道,
   *   让服务端说了算,不在本地猜。
   * 只刷继续观看,**不整页 onRefresh()**:整页刷会把 Hero 重新随机掉,
   *   用户只是右键了一张卡,不该整屏跟着变。 */
  async function markPlayed(it: Item, played: boolean) {
    setCtx(null);
    try {
      await setPlayed(it.id, played);
      setResume(await listResume(12));
    } catch (e) {
      setToast(`标记失败:${e}`);
    }
  }

  /** 顶栏随内容滚动淡出(标注 4)。直接写 DOM 上的 CSS 变量,不走 state ——
      滚动每帧 setState 会把整页(含所有海报)重渲一遍。 */
  const onScroll = (e: { currentTarget: HTMLDivElement }) => {
    const el = cbarRef.current;
    if (!el) return;
    el.style.setProperty("--cbar-fade", String(Math.max(0, 1 - e.currentTarget.scrollTop / 140)));
  };

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
      {/* 不写 inline style 设默认值:那样 React 每次重渲都可能把 --cbar-fade 抹回 1,
          滚到一半弹个 toast 顶栏就闪回来。默认值交给 CSS 的 var(--cbar-fade, 1) 回落。 */}
      <div className="cbar" ref={cbarRef}>
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

      <div className="scroll" onScroll={onScroll}>
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
                  className="hm-arrow left"
                  title="上一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(-1);
                  }}
                >
                  <IconChevronLeft size={16} />
                </button>
                <button
                  className="hm-arrow right"
                  title="下一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(1);
                  }}
                >
                  <IconChevronRight size={16} />
                </button>
              </>
            )}

            <div className="hero-body">
              <div className="hero-eyebrow">随机推荐</div>
              {/* 标注 6:有 logo 用 logo,取不到就回落文字标题(见 logoUrl 上的注释)。 */}
              {logoFail.has(hero.id) ? (
                <div className="hero-title">{hero.name}</div>
              ) : (
                <img
                  key={hero.id}
                  className="hm-herologo"
                  src={logoUrl(session, hero.id)}
                  alt={hero.name}
                  onError={() => setLogoFail((s) => new Set(s).add(hero.id))}
                />
              )}
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
                {resume.map((it) => (
                  <div className="r-wide" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      onContextMenu={openCtx}
                    />
                  </div>
                ))}
              </Rail>
            </section>
          )}

          {/* 合集轨道(草稿 L643-649:16:9 卡)。BoxSet 是文件夹 → 卡片单击就是进合集详情。 */}
          {collections.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">合集</span>
              </div>
              <Rail>
                {collections.map((c) => (
                  <div className="r-wide" key={c.id}>
                    <Poster
                      item={c}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      onContextMenu={openCtx}
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
                    {items.map((it) => (
                      <div className="r-poster" key={it.id}>
                        <Poster
                          item={it}
                          session={session}
                          onOpen={onOpenItem}
                          onContextMenu={openCtx}
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

      {/* 右键菜单**只有首页有**,且只有这三项(用户 2026-07-15 定,覆盖草稿标注 7)。
          原来的「播放 / 查看详情 / 移出继续观看」已按此删除:
          单击本身就是进详情,而「标记为已播放」在 Emby 里就等于把它移出继续观看。
          标记两项都常驻(不做 toggle):用户点名的就是「标记为未/已播放」两条。 */}
      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {/* 每项都得自己 setCtx(null):菜单容器 stopPropagation 了,关菜单的 window click 到不了这。 */}
          <div className="mi" onClick={() => void markPlayed(ctx.item, true)}>
            <IconCheck size={15} /> 标记为已播放
          </div>
          <div className="mi" onClick={() => void markPlayed(ctx.item, false)}>
            <IconCheck size={15} /> 标记为未播放
          </div>
          {/* 已在喜欢里还显示「添加到喜欢」就是骗人 → 标签跟着实际状态走,仍是一项。 */}
          <div
            className="mi"
            onClick={() => {
              toggleFav(ctx.item);
              setCtx(null);
            }}
          >
            <IconHeart size={15} /> {favIds.has(ctx.item.id) ? "从喜欢中移除" : "添加到喜欢"}
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
