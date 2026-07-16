import { useCallback, useEffect, useState } from "react";
import {
  type Item,
  type RankingCategory,
  type RankingEntry,
  type ServerGroup,
  aggregateSearch,
  itemLabel,
  rankingCategories,
  rankingFetch,
  setActiveServer,
} from "../lib/api";
import { IconClose, IconRanking, IconRefresh } from "../app/icons";
import "./RankingsPage.css";

// 榜单分组 → 左栏小标题(anime=追番榜,movie/tv=影视热榜)。
function groupLabel(g: RankingCategory["group"]): string {
  return g === "anime" ? "追番榜" : "影视热榜";
}

export default function RankingsPage({
  onOpenItem,
}: {
  /** 跨服找到片源后直接开详情(Shell 传 openFromSearch)。不传就只切服务器 + 提示。 */
  onOpenItem?: (item: Item, serverId: string) => void;
}) {
  const [cats, setCats] = useState<RankingCategory[] | null>(null);
  const [active, setActive] = useState<string>("");
  const [entries, setEntries] = useState<RankingEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  // 点开的榜单项标题 → 跨服找可播源弹窗(草稿 33)。
  const [pick, setPick] = useState<string | null>(null);

  // 分类清单只取一次(空数组 = 未注入凭据 → 整页诚实空态)。
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const list = await rankingCategories();
        if (!alive) return;
        setCats(list);
        if (list.length > 0) setActive(list[0].id);
      } catch (e) {
        if (alive) {
          setCats([]);
          setErr(String(e));
        }
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  const load = useCallback(async (categoryId: string, force: boolean) => {
    if (!categoryId) return;
    setErr("");
    if (force) setRefreshing(true);
    else setEntries(null);
    try {
      const list = await rankingFetch(categoryId, force);
      setEntries(list);
    } catch (e) {
      setEntries([]);
      setErr(String(e));
    } finally {
      setRefreshing(false);
    }
  }, []);

  // 切分类即拉榜(强刷走刷新按钮)。
  useEffect(() => {
    if (active) load(active, false);
  }, [active, load]);

  // 凭据未注入 → 诚实告知,不造假榜。
  if (cats != null && cats.length === 0) {
    return (
      <>
        <div className="cbar">
          <span className="crumb">
            <b>排行榜</b>
          </span>
        </div>
        <div className="scroll">
          <div className="empty">
            当前构建未注入榜单凭据(弹弹Play / TMDB),发布版才亮榜
          </div>
        </div>
      </>
    );
  }

  const activeLabel = cats?.find((c) => c.id === active)?.label ?? "";

  // 按显示分组聚合(movie+tv 合并进「影视热榜」),保持首次出现顺序。
  const groups: { label: string; cats: RankingCategory[] }[] = [];
  for (const c of cats ?? []) {
    const gl = groupLabel(c.group);
    let g = groups.find((x) => x.label === gl);
    if (!g) {
      g = { label: gl, cats: [] };
      groups.push(g);
    }
    g.cats.push(c);
  }

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>排行榜</b>
          {activeLabel && (
            <>
              <span className="sep">›</span>
              {activeLabel}
            </>
          )}
        </span>
        <span className="push">
          <button
            type="button"
            className="ibtn"
            title="强制刷新"
            onClick={() => load(active, true)}
            disabled={!active || refreshing}
          >
            <IconRefresh size={15} className={refreshing ? "rk-spin" : undefined} />
          </button>
        </span>
      </div>

      <div className="scroll">
        <div className="rkwrap">
          {/* 左栏:榜单分组 + 分类,常驻可点。 */}
          <div className="rkrail">
            {cats == null
              ? Array.from({ length: 6 }).map((_, i) => (
                  <div className="li" key={i}>
                    <span className="rad" />
                    <span
                      className="skeleton"
                      style={{ height: 12, width: 64, borderRadius: 4 }}
                    />
                  </div>
                ))
              : groups.map((g) => (
                  <div key={g.label}>
                    <div className="grp-lab">{g.label}</div>
                    {g.cats.map((c) => (
                      <div
                        key={c.id}
                        className={`li${c.id === active ? " on" : ""}`}
                        onClick={() => setActive(c.id)}
                      >
                        <span className="rad" />
                        {c.label}
                      </div>
                    ))}
                  </div>
                ))}
          </div>

          {/* 右栏:海报网格 + 名次角标 + 评分(外部数据,不可播放)。
              ★ .rk-main 这个 class 不能省:它是 .rkwrap 的 flex 子元素,
                flex:1/min-width:0 得挂在它身上,网格才有确定宽度(见 CSS 里的长注释)。 */}
          <div className="rk-main">
            {err ? (
              <div className="empty">加载失败：{err}</div>
            ) : entries == null ? (
              <div className="rankgrid">
                {Array.from({ length: 18 }).map((_, i) => (
                  <div className="rk-item" key={i}>
                    <div className="rankcell poster skeleton" />
                    <span className="skeleton" style={{ height: 11, borderRadius: 4 }} />
                  </div>
                ))}
              </div>
            ) : entries.length === 0 ? (
              <div className="empty">这个榜单暂时没有数据</div>
            ) : (
              <div className="rankgrid">
                {entries.map((e) => (
                  <RankCell key={e.id} entry={e} onPick={() => setPick(e.title)} />
                ))}
              </div>
            )}
          </div>
        </div>
        <div style={{ height: 40 }} />
      </div>

      {pick && <SourcePicker title={pick} onOpenItem={onOpenItem} onClose={() => setPick(null)} />}
    </>
  );
}

/* ============================================================
   跨服找可播源弹窗 —— 榜单(草稿 33)与日历(草稿 44)共用一份。
   榜单/日历条目来自**外部数据源**(弹弹Play / TMDB / Trakt / Bangumi),
   它本身不是任何一台服务器上的条目 —— 正因如此才需要这个弹窗:
   拿标题去 aggregateSearch 反查「我的哪台服务器上有这片」。
   这不是「非可播放所以不绑跳转」,弹窗本身就是那次跨服查找。
   ============================================================ */
export function SourcePicker({
  title,
  onOpenItem,
  onClose,
}: {
  title: string;
  /** Shell 给了才能真跳详情/起播;没给就只切活跃服务器并如实说明(见文件末注)。 */
  onOpenItem?: (item: Item, serverId: string) => void;
  onClose: () => void;
}) {
  const [groups, setGroups] = useState<ServerGroup[] | null>(null);
  const [err, setErr] = useState("");
  const [note, setNote] = useState("");

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const g = await aggregateSearch(title);
        // 空组不占位:没有结果的服务器列出来只是噪音。
        if (alive) setGroups(g.filter((x) => x.items.length > 0));
      } catch (e) {
        if (alive) {
          setGroups([]);
          setErr(String(e));
        }
      }
    })();
    return () => {
      alive = false;
    };
  }, [title]);

  // Esc 关(与全站右键菜单同约定)。
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function pick(item: Item, g: ServerGroup) {
    try {
      // 先切活跃服务器:后续 item_detail / play 都打活跃服务器,不切就会去错服务器找 id。
      await setActiveServer(g.server_id);
    } catch (e) {
      setErr(String(e));
      return;
    }
    if (onOpenItem) {
      onOpenItem(item, g.server_id);
      onClose();
      return;
    }
    // 没有跳转回调时不装作跳过去了 —— 活跃服务器**确实**切了,只把下一步如实说清。
    setNote(`已切换到「${g.server_name}」。可在 媒体库 / 搜索 中打开「${item.name}」。`);
  }

  const total = (groups ?? []).reduce((n, g) => n + g.items.length, 0);

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dlg wide" onClick={(e) => e.stopPropagation()}>
        <div className="dhd">
          跨服查找可播源 · {title}
          <button className="x" onClick={onClose}>
            <IconClose size={15} />
          </button>
        </div>
        <div className="dbd">
          {groups == null ? (
            <div className="empty">
              <span className="spinner" />
            </div>
          ) : err ? (
            <div className="empty">查找失败：{err}</div>
          ) : total === 0 ? (
            <div className="empty">你的服务器上没有找到「{title}」。</div>
          ) : (
            <>
              {note && <div className="caption-note rk-pick-note">{note}</div>}
              {groups.map((g) => (
                <div key={g.server_id}>
                  <div className="rk-pick-srv">
                    {g.server_name}
                    <span className="c">· {g.items.length}</span>
                  </div>
                  {g.items.map((it) => (
                    <div
                      className="rk-pick-row"
                      key={`${g.server_id}:${it.id}`}
                      onClick={() => pick(it, g)}
                    >
                      <span className="rk-pick-t">{itemLabel(it)}</span>
                      <span className="rk-pick-m">
                        {[it.type_, it.year].filter(Boolean).join(" · ")}
                      </span>
                    </div>
                  ))}
                </div>
              ))}
            </>
          )}
        </div>
        <div className="dft">
          <button className="btn" onClick={onClose}>
            关闭
          </button>
        </div>
      </div>
    </div>
  );
}

// 海报 + 名次角标(前三金银铜)+ 评分 + 标题;点海报 → 跨服找可播源弹窗(草稿 33)。
function RankCell({ entry, onPick }: { entry: RankingEntry; onPick: () => void }) {
  const medal = entry.rank <= 3 ? ` g${entry.rank}` : "";
  const [loaded, setLoaded] = useState(false);
  return (
    <div className="rk-item">
      <div className="rankcell poster tap" title={entry.title} onClick={onPick}>
        {entry.image_url && !loaded && <div className="rk-skel skeleton" />}
        {entry.image_url ? (
          <img
            className={`rk-img${loaded ? " ready" : ""}`}
            src={entry.image_url}
            loading="lazy"
            decoding="async"
            alt={entry.title}
            onLoad={() => setLoaded(true)}
            onError={(ev) => {
              setLoaded(true); // 失败也撤骨架,否则永远 shimmer
              (ev.target as HTMLImageElement).style.visibility = "hidden";
            }}
          />
        ) : (
          <div className="rk-ph">
            <IconRanking size={26} />
          </div>
        )}
        <span className={`rk${medal}`}>{entry.rank}</span>
        {/* 评分:0 分不画 —— 两个源都拿 0 表示「没评分」,画出来会变成「这片 0 分」的诽谤。 */}
        {entry.rating != null && entry.rating > 0 && (
          <span className={`rate${entry.rating >= 8 ? " hi" : ""}`} title={`评分 ${entry.rating}`}>
            <i className="s">★</i>
            {entry.rating.toFixed(1)}
          </span>
        )}
      </div>
      <span className="rk-cap" title={entry.title}>
        {entry.title}
      </span>
    </div>
  );
}
