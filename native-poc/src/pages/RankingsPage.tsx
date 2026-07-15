import { useCallback, useEffect, useState } from "react";
import {
  type RankingCategory,
  type RankingEntry,
  rankingCategories,
  rankingFetch,
} from "../lib/api";
import { IconRanking, IconRefresh } from "../app/icons";
import "./RankingsPage.css";

// 榜单分组 → 左栏小标题(anime=追番榜,movie/tv=影视热榜)。
function groupLabel(g: RankingCategory["group"]): string {
  return g === "anime" ? "追番榜" : "影视热榜";
}

export default function RankingsPage() {
  const [cats, setCats] = useState<RankingCategory[] | null>(null);
  const [active, setActive] = useState<string>("");
  const [entries, setEntries] = useState<RankingEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [refreshing, setRefreshing] = useState(false);

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

          {/* 右栏:海报网格 + 名次角标 + 评分(外部数据,不可播放)。 */}
          <div>
            {err ? (
              <div className="empty">加载失败：{err}</div>
            ) : entries == null ? (
              <div className="rankgrid">
                {Array.from({ length: 12 }).map((_, i) => (
                  <div className="rankcell poster skeleton" key={i} />
                ))}
              </div>
            ) : entries.length === 0 ? (
              <div className="empty">这个榜单暂时没有数据</div>
            ) : (
              <div className="rankgrid">
                {entries.map((e) => (
                  <RankCell key={e.id} entry={e} />
                ))}
              </div>
            )}
          </div>
        </div>
        <div style={{ height: 40 }} />
      </div>
    </>
  );
}

// 榜单项 = 外部数据、非可播放条目 → 不绑跳转(cursor default),只保留悬停轻浮起。
function RankCell({ entry }: { entry: RankingEntry }) {
  const medal = entry.rank <= 3 ? ` g${entry.rank}` : "";
  return (
    <div className="rankcell poster" title={entry.title}>
      {entry.image_url ? (
        <img
          className="rk-img"
          src={entry.image_url}
          loading="lazy"
          alt={entry.title}
          onError={(ev) =>
            ((ev.target as HTMLImageElement).style.visibility = "hidden")
          }
        />
      ) : (
        <div className="rk-ph">
          <IconRanking size={28} />
        </div>
      )}
      <span className={`rk${medal}`}>{entry.rank}</span>
      {entry.rating != null && (
        <span className="rate">★{entry.rating.toFixed(1)}</span>
      )}
    </div>
  );
}
