import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  aggregateSearch,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  itemDetail,
  itemMedia,
  listAccounts,
  play,
  posterUrl,
  setFavorite,
  setPlayed,
  thumbUrl,
  type AccountInfo,
  type Item,
  type LoginResult,
  type MediaVersion,
  type StreamInfo,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { FocusColumn, FocusItem, FocusRow } from "../components/Focus";
import { useAsync } from "../lib/useAsync";

/** 集详情(草稿 15)。**版本 / 音轨 / 字幕的选择全部集中在这一页** ——
    剧的层级上没有"版本"这回事,每一集的片源都可能来自不同来源、规格也不同,
    所以剧详情页一个都不放。

    ★ 底部是**集数栏**,不是「上一集 / 下一集」两个按钮:两个按钮一次只能挪一格,
      24 集的番要按 18 次。集数栏一次可见 13 集,横向直达。
    ★ 换集**不回上层**:集数栏切集只换本页内容(itemId 换成新的一集),
      版本行跟着重新聚合。 */
export default function EpisodePage({
  session,
  go,
  itemId,
}: {
  session: LoginResult;
  go: (r: Route) => void;
  itemId?: string;
}) {
  /* 当前这一集。集数栏切集改的是它,不动路由栈 —— 退出时按一次返回就回剧详情,
     而不是"切了几集就要按几次"。 */
  const [curId, setCurId] = useState(itemId ?? "");
  const ep = useAsync(() => itemDetail(curId), [curId]);
  const d = ep.data;

  /* 剧本体单独一块各自加载:集数栏要的是**整季的分集表**,而分集详情里没有。
     不和上面并到一个 Promise.all 里 —— 分集详情先回来,顶部就先画出来。 */
  const seriesId = d?.series_id ?? null;
  const series = useAsync(
    () => (seriesId ? itemDetail(seriesId) : Promise.resolve(null)),
    [seriesId],
  );

  /* 同季分集。跨季混在一起会让 E01 出现两次(第一季和第二季各一个)。 */
  const episodes = useMemo(
    () =>
      (series.data?.children ?? []).filter(
        (c) => d?.season_no == null || c.season_no === d.season_no,
      ),
    [series.data, d?.season_no],
  );
  /* 本集在分集表里的那一行 —— ItemDetail 不带 played,已看状态只有这里有。
     拿不到就整个「标记已看」按钮不渲染,而不是猜一个默认值画上去。 */
  const cur = episodes.find((e) => e.id === curId) ?? null;

  const [view, setView] = useEpView();
  const [fav, setFav] = useState<boolean | null>(null);
  const [played, setPlayedLocal] = useState<boolean | null>(null);
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => setFav(d?.is_favorite ?? null), [d?.is_favorite]);
  useEffect(() => setPlayedLocal(cur?.played ?? null), [cur?.played]);

  if (!itemId) return <Empty text="没有指定要播放的分集。" />;
  if (ep.err) return <Empty text={ep.err.message} />;
  if (!d) return <Empty text="载入中…" />;

  const resume = d.resume_secs > 1 ? d.resume_secs : 0;
  const start = async (secs: number) => {
    setMsg(null);
    try {
      await play(curId, secs, ver?.id ?? null);
      go({ page: "player" });
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div style={{ position: "relative", height: "100%", padding: "48px 64px" }}>
      <FocusColumn focusKey="EPISODE">
        <div style={{ fontSize: 19, color: "var(--tv-ink-3)", marginBottom: 10 }}>
          {[d.series_name, d.season_no != null ? `第 ${d.season_no} 季` : null]
            .filter(Boolean)
            .join(" · ")}
        </div>
        <h3 style={{ fontSize: 36, fontWeight: 700, letterSpacing: "-.02em", margin: "0 0 10px" }}>
          {d.episode_no != null ? `E${d.episode_no} · ${d.name}` : d.name}
        </h3>

        {/* 顶部**不重复规格**:编码 / 音轨 / 字幕都在版本卡上,这里只留时长和剩余。 */}
        <div style={META}>
          {d.runtime_secs > 0 && <span>{Math.round(d.runtime_secs / 60)} 分钟</span>}
          {resume > 0 && d.runtime_secs > resume && (
            <span>剩 {Math.round((d.runtime_secs - resume) / 60)} 分钟</span>
          )}
        </div>

        {/* ★ 切到「详细」时顶部简介必须消失 —— 详细卡自带简介,
            同一段话不该在一屏里出现两次。 */}
        {view === "compact" && d.overview && <p style={SYNOPSIS}>{d.overview}</p>}

        {resume > 0 && d.runtime_secs > 0 && (
          <div style={BAR}>
            <i
              style={{
                display: "block",
                height: "100%",
                borderRadius: 4,
                background: "var(--accent)",
                width: `${Math.min(100, (resume / d.runtime_secs) * 100)}%`,
              }}
            />
          </div>
        )}

        <div className="btnrow" style={{ marginBottom: 36 }}>
          <FocusItem className="btn pri fx" autoFocus onEnter={() => void start(resume)}>
            <Icon n="play" className="ic ic-btn" />
            {resume > 0 ? `继续播放 ${fmtTime(resume)}` : "播放"}
          </FocusItem>
          {resume > 0 && (
            <FocusItem className="btn fx" onEnter={() => void start(0)}>
              从头播放
            </FocusItem>
          )}
          {played != null && (
            <FocusItem
              className="btn fx"
              onEnter={() => {
                const next = !played;
                setPlayedLocal(next);
                void setPlayed(curId, next).catch(() => setPlayedLocal(!next));
              }}
            >
              <Icon n="check" className="ic ic-btn" />
              {played ? "标记未看" : "标记已看"}
            </FocusItem>
          )}
          <FocusItem
            className={`btn fx${fav ? " pri" : ""}`}
            onEnter={() => {
              const next = !fav;
              setFav(next);
              void setFavorite(curId, next).catch(() => setFav(!next));
            }}
          >
            <Icon n="heart" className="ic ic-btn" />
            {fav ? "已收藏" : "收藏"}
          </FocusItem>
          <FocusItem
            className="btn fx"
            onEnter={() => {
              /* container 拿不到就传空串:核层会兜成 mkv。别在前端瞎写一个扩展名 ——
                 落盘文件名会跟着错。 */
              void downloadEnqueue(
                curId,
                "Episode",
                d.series_name ? `${d.series_name} · ${d.name}` : d.name,
                ver?.container ?? "",
                posterUrl(session, curId, 480),
              )
                .then(() => setMsg("已加入下载队列"))
                .catch((e) => setMsg(e instanceof Error ? e.message : String(e)));
            }}
          >
            <Icon n="download" className="ic ic-btn" />
            下载
          </FocusItem>
        </div>

        {msg && <div style={{ color: "var(--tv-ink-2)", fontSize: 19, marginBottom: 18 }}>{msg}</div>}

        <VersionRow
          itemId={curId}
          matchTitle={d.series_name ?? series.data?.name ?? null}
          /* ★ 「系列名」是跨来源认定同一集的唯一依据,而**有服务端不给**
             (Episode.SeriesName 缺失)。这时只能拿上层剧条目的名字顶上,
             置信度不足 → 卡片打「可能匹配」黄标,不假装是精确匹配。 */
          titleConfident={d.series_name != null}
          onSelect={setVer}
        />

        {/* 集数栏紧跟版本行,**不用 margin-top:auto 贴底** ——
            贴底会在版本行和集数栏之间留一大块空,焦点从版本走到集数要跨过一段虚无。 */}
        {episodes.length > 0 && (
          <>
            <div className="rowhead" style={{ marginBottom: 14 }}>
              <div className="t">选集</div>
              <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>
                {[d.season_no != null ? `第 ${d.season_no} 季` : null, `共 ${episodes.length} 集`]
                  .filter(Boolean)
                  .join(" · ")}
              </div>
              <div className="epsw" style={{ marginLeft: "auto" }}>
                <FocusItem
                  className={view === "compact" ? "on" : ""}
                  onEnter={() => setView("compact")}
                >
                  紧凑
                </FocusItem>
                <FocusItem
                  className={view === "detail" ? "on" : ""}
                  onEnter={() => setView("detail")}
                >
                  详细
                </FocusItem>
              </div>
            </div>
            {view === "compact" ? (
              <CompactStrip eps={episodes} curId={curId} onPick={setCurId} />
            ) : (
              <FocusRow className="epwrap" trackClass="track">
                {episodes.map((e) => (
                  <EpisodeCard
                    key={e.id}
                    e={e}
                    session={session}
                    on={e.id === curId}
                    onEnter={() => setCurId(e.id)}
                  />
                ))}
              </FocusRow>
            )}
          </>
        )}
      </FocusColumn>
    </div>
  );
}

/* ------------------------------------------------------------
   版本行 —— 集详情页和**电影详情页共用同一个组件**。
   同一个概念做两套视觉,用户每换一页就要重新认一遍。
   ------------------------------------------------------------ */

/** 一次探测的结果。
 *  ★ opaque 这个态是真实存在的能力边界,不是偷懒:核层只有 `item_media`(打**当前**
 *    服务器)和 `aggregate_search`(跨服搜,但只回 Movie/Series 且**不带 MediaSources**)。
 *    没有任何一个已导出命令能拿到"另一台 Emby 上这个条目的 MediaSource"。
 *    所以别台服务器只能确认"有没有这部",规格未知 —— 那就如实说未知,
 *    不编一个分辨率画上去。 */
type Probe =
  | { kind: "probing" }
  | { kind: "ok"; versions: MediaVersion[] }
  | { kind: "absent" }
  | { kind: "opaque"; maybe: boolean };

type VCard = {
  key: string;
  serverName: string;
  current: boolean;
  probe: Probe;
  v: MediaVersion | null;
};

export function VersionRow({
  itemId,
  matchTitle,
  titleConfident,
  onSelect,
}: {
  itemId: string;
  /** 跨来源认定"同一个条目"用的名字。null = 认不出来,别台服务器整个不探。 */
  matchTitle: string | null;
  titleConfident: boolean;
  onSelect: (v: MediaVersion | null) => void;
}) {
  const [accounts, setAccounts] = useState<AccountInfo[]>([]);
  const [probes, setProbes] = useState<Record<string, Probe>>({});
  const [sel, setSel] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setProbes({});
    setSel(null);
    void (async () => {
      /* ★ 只聚合 Emby。网盘 / OpenList / 飞牛没有 MediaSource 这个概念,
         要聚合就得逐个探测文件在不在 —— 为一行选择器做这件事不划算。 */
      const accs = (await listAccounts().catch(() => [] as AccountInfo[])).filter(
        (a) => a.source_kind === "Emby",
      );
      if (!alive) return;
      setAccounts(accs);

      /* ★★ 必须异步回填,**不许等齐再渲染**:当前来源本地就能问到,立刻出;
         其它来源回来一个填一个。等齐 = 进页白屏两秒。 */
      const me = accs.find((a) => a.active);
      if (me) {
        itemMedia(itemId)
          .then((vs) => {
            if (!alive) return;
            setProbes((p) => ({ ...p, [me.server]: { kind: "ok", versions: vs } }));
          })
          .catch(() => {
            if (alive) setProbes((p) => ({ ...p, [me.server]: { kind: "absent" } }));
          });
      }

      const others = accs.filter((a) => !a.active);
      if (others.length === 0) return;
      const mark = (f: (a: AccountInfo) => Probe) =>
        setProbes((p) => {
          const n = { ...p };
          for (const a of others) n[a.server] = f(a);
          return n;
        });
      if (!matchTitle) {
        /* 连名字都没有 → 无从认定,如实标"认不出"而不是留一排永远转圈的卡。 */
        mark(() => ({ kind: "absent" }));
        return;
      }
      const groups = await aggregateSearch(matchTitle).catch(() => []);
      if (!alive) return;
      mark((a) => {
        const hit = groups
          .find((g) => g.server_id === a.server)
          ?.items.some((it) => norm(it.name) === norm(matchTitle));
        return hit ? { kind: "opaque", maybe: !titleConfident } : { kind: "absent" };
      });
    })();
    return () => {
      alive = false;
    };
  }, [itemId, matchTitle, titleConfident]);

  const cards = useMemo(() => buildCards(accounts, probes), [accounts, probes]);

  /* 默认选中排序后的第一张(= 当前来源里分辨率/码率最高的那版)。
     ★ 焦点**不**用 autoFocus 抢:版本卡是异步回填的,挂载时抢焦点会把用户
       刚落在「继续播放」上的焦点偷走。落进这一行时库自己会走到第一张。 */
  const first = cards.find((c) => c.v)?.v ?? null;
  useEffect(() => {
    if (!first) return;
    setSel((s) => s ?? first.id);
    onSelect(first);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [first?.id]);

  /* 只有一个版本、也没有别的 Emby 可比 → 整行不渲染。
     留一个"只能选它自己"的选择器纯属占版面。 */
  if (cards.length <= 1) return null;

  return (
    <>
      <div className="rowhead" style={{ marginBottom: 16 }}>
        <div className="t">版本</div>
        <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>
          来自 {accounts.length} 台 Emby 服务器
        </div>
      </div>
      <FocusRow trackClass="track breathe">
        {cards.map((c) => (
          <VersionCard
            key={c.key}
            c={c}
            on={c.v != null && c.v.id === sel}
            onEnter={() => {
              if (!c.v) return;
              setSel(c.v.id);
              onSelect(c.v);
            }}
          />
        ))}
      </FocusRow>
      <div style={{ height: 30 }} />
    </>
  );
}

/** 排序 = **当前来源 → 分辨率降序 → 码率降序**。最可能想要的那张必须排第一。
 *  拿不到规格的(还在查 / 只知道有)排在真版本之后,确认没有的垫底。 */
function buildCards(accounts: AccountInfo[], probes: Record<string, Probe>): VCard[] {
  const out: VCard[] = [];
  for (const a of accounts) {
    const p = probes[a.server] ?? { kind: "probing" };
    if (p.kind === "ok") {
      for (const v of p.versions)
        out.push({ key: `${a.server}:${v.id}`, serverName: a.name, current: a.active, probe: p, v });
      if (p.versions.length === 0)
        out.push({ key: a.server, serverName: a.name, current: a.active, probe: { kind: "absent" }, v: null });
    } else {
      out.push({ key: a.server, serverName: a.name, current: a.active, probe: p, v: null });
    }
  }
  const rank = (c: VCard) => (c.v ? 0 : c.probe.kind === "absent" ? 2 : 1);
  return out.sort(
    (x, y) =>
      rank(x) - rank(y) ||
      Number(y.current) - Number(x.current) ||
      (height(y.v) - height(x.v)) ||
      ((y.v?.bitrate ?? 0) - (x.v?.bitrate ?? 0)),
  );
}

/** 380×212dp。信息四层:来源 18sp / **分辨率 30sp(最大)** / 编码·码率·体积 17sp / 音轨·字幕 16sp。
 *  分辨率最大是因为它是三米外唯一一眼可辨的字段。 */
function VersionCard({ c, on, onEnter }: { c: VCard; on: boolean; onEnter: () => void }) {
  const v = c.v;
  return (
    <FocusItem
      className={`vcard fx${on ? " on" : ""}${v ? "" : " off"}`}
      /* ★ 不可用来源**保留但不可聚焦**:整张消失会让用户以为片源丢了,
         可聚焦又白白多按一次方向键才能越过去。 */
      disabled={!v}
      onEnter={onEnter}
    >
      <div className="src">
        <Icon n="server" className="ic" />
        {c.serverName}
        {c.current && <span className="tag">当前</span>}
      </div>
      {v ? (
        <>
          <div className="res">{resLabel(v)}</div>
          <div className="spec">{specLabel(v)}</div>
          {/* ★ 版本卡**不显示观看进度** —— 起播一律接当前进度,
              不管这个版本在别的服务器上被看到哪。 */}
          <div className="trk">{trackLabel(v)}</div>
        </>
      ) : (
        <>
          <div className="res" style={{ color: "var(--tv-ink-3)" }}>
            —
          </div>
          <div className="spec">
            {c.probe.kind === "probing" ? "查询中…" : c.probe.kind === "absent" ? "此来源没有该条目" : "已找到,规格未知"}
          </div>
          {c.probe.kind === "opaque" && (
            <div className="trk">切换到该服务器后可看规格</div>
          )}
        </>
      )}
      {c.probe.kind === "opaque" && c.probe.maybe && <div className="warn">可能匹配</div>}
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   集数栏
   ------------------------------------------------------------ */

/** 紧凑视图:集号 chip,**选中恒居中**,两端渐隐(.epwrap)。 */
function CompactStrip({
  eps,
  curId,
  onPick,
}: {
  eps: Item[];
  curId: string;
  onPick: (id: string) => void;
}) {
  const wrap = useRef<HTMLDivElement>(null);

  /* 居中靠自己算:FocusRow 自带的滚动只保证"焦点看得见",不保证居中。
     ★ 用 offsetLeft / clientWidth 而不是 getBoundingClientRect ——
       .tv-app 上有 zoom,gBCR 返回缩放后的设备 px,而 transform 吃的是未缩放的 CSS px,
       两者混用会让位移只走该走的 61%(见 Focus.tsx 的 zoomOf 注释)。
       offset* 系列是布局值,天生不受 zoom 影响,省掉一次换算。 */
  useEffect(() => {
    const strip = wrap.current?.querySelector<HTMLElement>(".epstrip");
    const view = strip?.parentElement;
    const sel = strip?.querySelector<HTMLElement>("[data-cur='1']");
    if (!strip || !view || !sel) return;
    const center = sel.offsetLeft + sel.offsetWidth / 2 - view.clientWidth / 2;
    /* 左端不过界:第 1 集"居中"意味着左边空掉半屏,那比不居中更难看。 */
    strip.style.transform = `translateX(${-Math.max(0, center)}px)`;
  }, [curId, eps.length]);

  return (
    <div ref={wrap}>
      <FocusRow className="epwrap" trackClass="epstrip">
        {eps.map((e) => (
          <FocusItem
            key={e.id}
            className={`ep${e.played ? " done" : ""}${e.id === curId ? " on" : ""}`}
            onEnter={() => onPick(e.id)}
          >
            {/* data 属性只给上面那段居中计算认人用,不参与样式 */}
            <span data-cur={e.id === curId ? "1" : "0"}>
              {e.episode_no != null ? `E${e.episode_no}` : e.name}
            </span>
          </FocusItem>
        ))}
      </FocusRow>
    </div>
  );
}

/** 详细视图:封面卡。卡片自带简介 → 顶部那段简介同步隐藏(见上面 view 分支)。 */
function EpisodeCard({
  e,
  session,
  on,
  onEnter,
}: {
  e: Item;
  session: LoginResult;
  on: boolean;
  onEnter: () => void;
}) {
  const pct = e.runtime_secs > 0 ? Math.min(100, (e.resume_secs / e.runtime_secs) * 100) : 0;
  return (
    <FocusItem className={`epcard fx${on ? " on" : ""}`} onEnter={onEnter}>
      <div className="th">
        {e.has_primary && <img src={thumbUrl(session, e.id, 640)} alt="" loading="lazy" />}
        {e.episode_no != null && <div className="no">E{e.episode_no}</div>}
        {pct > 0 && (
          <div className="prog">
            <i style={{ width: `${pct}%` }} />
          </div>
        )}
      </div>
      <div className="nm">{e.name}</div>
      <div className="du">
        {[
          e.runtime_secs > 0 ? `${Math.round(e.runtime_secs / 60)} 分钟` : null,
          e.played ? "已看完" : pct > 0 ? `剩 ${Math.round((e.runtime_secs - e.resume_secs) / 60)} 分钟` : null,
        ]
          .filter(Boolean)
          .join(" · ")}
      </div>
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   小工具
   ------------------------------------------------------------ */

/** 视图选择要**持久化**:切一次「详细」之后,下次进来还得是他要的那个。 */
function useEpView(): ["compact" | "detail", (v: "compact" | "detail") => void] {
  const [v, setV] = useState<"compact" | "detail">(() =>
    localStorage.getItem(EP_VIEW_KEY) === "detail" ? "detail" : "compact",
  );
  const set = useCallback((n: "compact" | "detail") => {
    setV(n);
    localStorage.setItem(EP_VIEW_KEY, n);
  }, []);
  return [v, set];
}
const EP_VIEW_KEY = "lp.tv.epview";

function Empty({ text }: { text: string }) {
  return (
    <div style={{ padding: "48px 64px" }}>
      <div className="psub">{text}</div>
    </div>
  );
}

const norm = (s: string) => s.toLowerCase().replace(/[\s·:：!！?？.、,,-]/g, "");

const videoOf = (v: MediaVersion): StreamInfo | null =>
  v.streams.find((s) => s.type_ === "Video") ?? null;
const height = (v: MediaVersion | null) => (v ? (videoOf(v)?.height ?? 0) : 0);

function resLabel(v: MediaVersion): string {
  const vs = videoOf(v);
  const r = fmtRes(vs?.height ?? null) || "未知";
  const hdr = vs?.video_range && vs.video_range.toUpperCase() !== "SDR" ? ` ${vs.video_range}` : "";
  return r + hdr;
}

/** ★ 码率必须给:只写「4K / 1080p」分不出好坏 —— 4 Mbps 的 2160p 压制不如 15 Mbps 的 1080p。 */
function specLabel(v: MediaVersion): string {
  return [videoOf(v)?.codec.toUpperCase(), fmtBitrate(v.bitrate), fmtSize(v.size_bytes)]
    .filter((x): x is string => !!x)
    .join(" · ");
}

/** 卡片上只**列出**有哪些音轨/字幕,不在这里逐条选(选定版本后进面板挑)。 */
function trackLabel(v: MediaVersion): string {
  const one = (s: StreamInfo) =>
    s.display_title ??
    [s.language, s.codec.toUpperCase(), s.channel_layout].filter((x): x is string => !!x).join(" ");
  const audio = v.streams.filter((s) => s.type_ === "Audio").slice(0, 2).map(one).join(" / ");
  const subs = v.streams
    .filter((s) => s.type_ === "Subtitle")
    .map((s) => s.language ?? s.display_title)
    .filter((x): x is string => !!x)
    .slice(0, 4)
    .join(" / ");
  return [audio || "无音轨", subs || "无字幕"].join(" · ");
}

const META: React.CSSProperties = {
  display: "flex",
  gap: 18,
  alignItems: "center",
  fontSize: 19,
  color: "var(--tv-ink-2)",
  marginBottom: 16,
};

const SYNOPSIS: React.CSSProperties = {
  fontSize: 16,
  lineHeight: 1.5,
  color: "var(--tv-ink-2)",
  maxWidth: 760,
  margin: "0 0 16px",
  display: "-webkit-box",
  WebkitLineClamp: 2,
  WebkitBoxOrient: "vertical",
  overflow: "hidden",
};

const BAR: React.CSSProperties = {
  height: 8,
  borderRadius: 4,
  background: "rgba(255,255,255,.18)",
  maxWidth: 940,
  marginBottom: 28,
};

