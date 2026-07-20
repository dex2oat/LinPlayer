import { useEffect, useMemo, useState } from "react";
import {
  backdropUrl,
  downloadEnqueue,
  fmtTime,
  itemDetail,
  itemMedia,
  personUrl,
  play,
  posterUrl,
  setFavorite,
  similarItems,
  thumbUrl,
  type Item,
  type ItemDetail,
  type LoginResult,
  type MediaVersion,
} from "@shared/api";
import type { Route } from "../App";
import { Icon } from "../app/icons";
import { CardPoster } from "../components/Cards";
import { FocusColumn, FocusItem, FocusRow } from "../components/Focus";
import { useAsync } from "../lib/useAsync";
import {
  MediaInfo,
  NO_PICKS,
  PickBar,
  VersionRow,
  applyPicks,
  type Picks,
} from "./EpisodePage";

/** 剧集详情(草稿 03)与电影详情(草稿 16)。两者共用 Hero,按 type_ 分支:
    剧集 → 季度 chip + 分集条;电影 → 版本行(电影没有"集"这一层,版本行只能留在本页)。

    ★ **剧集详情页不出现版本 / 音轨 / 字幕选择**:剧的层级上根本没有"版本"这回事,
      每一集的片源都可能来自不同来源、规格也不同。全部下放到集详情页。
    ★ **不画渐变也不画半透明底**:文字直接落在封面上。全屏渐变每帧都要重新合成,
      而且渐变边界远看是糊的。
    ★ **不显示线路,也不显示服务器地址** —— 线路只出现在线路管理页。 */
export default function DetailPage({
  session,
  go,
  itemId,
}: {
  session: LoginResult;
  go: (r: Route) => void;
  itemId?: string;
}) {
  const d = useAsync(() => itemDetail(itemId ?? ""), [itemId]);

  if (!itemId) return <Note text="没有指定要打开的条目。" />;
  if (d.err) return <Note text={d.err.message} />;
  if (!d.data) return <Note text="载入中…" />;

  return (
    <div style={{ position: "relative", height: "100%" }}>
      {/* 背景用 Backdrop(BackdropImageTags,不是 ImageTags);没有 backdrop 就退回封面。 */}
      <img
        src={
          d.data.has_backdrop
            ? backdropUrl(session, d.data.id, 1600)
            : posterUrl(session, d.data.id, 1080)
        }
        alt=""
        style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }}
      />
      {/* 内容整块压在 backdrop 上,不加任何底/描边(用户 2026-07-20 定,
          三种兜底方案逐条否掉的经过见 tv.css 顶部那段记录)。 */}
      <div style={{ position: "relative", height: "100%", padding: "48px 64px" }}>
        {d.data.type_ === "Movie" ? (
          <Movie d={d.data} session={session} go={go} />
        ) : (
          <Series d={d.data} session={session} go={go} />
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------
   剧集
   ------------------------------------------------------------ */

function Series({
  d,
  session,
  go,
}: {
  d: ItemDetail;
  session: LoginResult;
  go: (r: Route) => void;
}) {
  /* 季号列表由分集表推出来 —— 核层 detail() 对 Series 已经把全部集(跨季)一次给齐了,
     再单独拉一次季表纯属多一个往返。 */
  const seasons = useMemo(() => {
    const s = new Set<number>();
    for (const c of d.children) if (c.season_no != null) s.add(c.season_no);
    return [...s].sort((a, b) => a - b);
  }, [d.children]);

  const [season, setSeason] = useState<number | null>(null);
  const cur = season ?? seasons[0] ?? null;
  const eps = d.children.filter((c) => cur == null || c.season_no === cur);

  /* 「继续 SxEy」指向哪一集:先找看了一半的,没有就找第一集没看完的,再没有就第一集。
     这是用户按下播放键时唯一想知道的事,别让他自己去分集条里找。 */
  const next =
    d.children.find((c) => c.resume_secs > 1 && c.resume_secs < c.runtime_secs) ??
    d.children.find((c) => !c.played) ??
    d.children[0] ??
    null;

  return (
    <FocusColumn focusKey="DETAIL_SERIES">
      <Head d={d} extra={`${d.children.length} 集`} />
      <Buttons
        d={d}
        /* ★ 剧的层级不选版本 → 起播不传 mediaSourceId,由服务器给第一个。 */
        target={next}
        session={session}
        go={go}
        /* ★ 「继续 SxEy」和「从头播放」并列显式给出 —— PC 上这两个藏在右键菜单里,
           TV 上没有右键,不显式给就等于没有。 */
        label={
          next && next.season_no != null && next.episode_no != null
            ? `${next.resume_secs > 1 ? "继续" : "播放"} S${next.season_no}E${next.episode_no}`
            : "播放"
        }
      />

      {seasons.length > 1 && (
        <div className="filters" style={{ marginBottom: 22 }}>
          {/* 季度切换做成 chip 而不是下拉 —— 下拉在遥控器上要多按两次。
              切季只换下面的分集条,Hero 不动(整页重渲染会把焦点丢掉)。 */}
          {seasons.map((s) => (
            <FocusItem
              key={s}
              className={`fchip${s === cur ? " on" : ""}`}
              onEnter={() => setSeason(s)}
            >
              第 {s} 季
            </FocusItem>
          ))}
        </div>
      )}

      {eps.length > 0 && (
        <FocusRow>
          {eps.map((e) => (
            <EpisodeCard
              key={e.id}
              e={e}
              session={session}
              onEnter={() => go({ page: "episode", itemId: e.id })}
            />
          ))}
        </FocusRow>
      )}

      <Similar id={d.id} session={session} go={go} />
    </FocusColumn>
  );
}

/** 分集卡:已看完压暗 + 满进度条;看了一半的打「继续」角标。 */
function EpisodeCard({
  e,
  session,
  onEnter,
}: {
  e: Item;
  session: LoginResult;
  onEnter: () => void;
}) {
  const pct = e.runtime_secs > 0 ? Math.min(100, (e.resume_secs / e.runtime_secs) * 100) : 0;
  return (
    <FocusItem className={`card169 fx${e.played ? " dim" : ""}`} onEnter={onEnter}>
      <div className="th">
        {e.has_primary && <img src={thumbUrl(session, e.id, 640)} alt="" loading="lazy" />}
        {pct > 0 && !e.played && <div className="badge">继续</div>}
        {(pct > 0 || e.played) && (
          <div className="prog">
            <i style={{ width: `${e.played ? 100 : pct}%` }} />
          </div>
        )}
      </div>
      <div className="nm">
        {e.episode_no != null ? `E${e.episode_no} · ${e.name}` : e.name}
      </div>
      <div className="sub">
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
   电影
   ------------------------------------------------------------ */

function Movie({
  d,
  session,
  go,
}: {
  d: ItemDetail;
  session: LoginResult;
  go: (r: Route) => void;
}) {
  /* 版本 + 各条流。选择器行和底部媒体信息块共用这一份。 */
  const media = useAsync(() => itemMedia(d.id), [d.id]);
  const [picks, setPicks] = useState<Picks>(NO_PICKS);
  /** 当前生效的版本:用户没挑就是服务器给的第一个。 */
  const cur = picks.ver ?? media.data?.[0] ?? null;

  return (
    <FocusColumn focusKey="DETAIL_MOVIE">
      <Head
        d={d}
        extra={d.runtime_secs > 0 ? `${Math.round(d.runtime_secs / 60)} 分钟` : null}
      />
      <Buttons
        d={d}
        target={null}
        session={session}
        go={go}
        label={d.resume_secs > 1 ? `继续播放 ${fmtTime(d.resume_secs)}` : "播放"}
        version={cur}
        picks={picks}
      />

      {/* ★ 播放键正下方的四个入口(用户 2026-07-20 评审:「想看前调不了」)。 */}
      <PickBar fk="MOVIE" versions={media.data} cur={cur} picks={picks} onPicks={setPicks} />

      {/* ★ 电影有版本行(电影没有"集"这一层),但用的是**集详情页那一套完全相同的版本卡** ——
          同一个概念两套视觉,用户每换一页就要重新认一遍。
          它和 PickBar 的「版本」选的是同一件事(本机这几个 MediaSource),只是它还多画了
          「别台 Emby 有没有这部」这一层,所以两个共用同一份 picks.ver,不各记各的。 */}
      <VersionRow
        itemId={d.id}
        matchTitle={d.name}
        titleConfident
        onSelect={(v) => setPicks((p) => ({ ...p, ver: v }))}
      />

      {d.people.length > 0 && (
        <>
          <div className="rowhead">
            <div className="t">演职人员</div>
          </div>
          {/* 头像**不可聚焦**:没有"该演员的作品列表"这个页面,能聚焦就是按下去没反应,
              比不能聚焦更糟。等那一页落地了再把它换成 FocusItem。 */}
          <div className="track">
            {d.people.slice(0, 12).map((p) => (
              <div key={p.id} style={{ width: 150, textAlign: "center", flex: "none" }}>
                <div
                  style={{
                    width: 150,
                    height: 150,
                    borderRadius: "50%",
                    overflow: "hidden",
                    background: "linear-gradient(135deg,var(--ph),var(--ph-2))",
                  }}
                >
                  {p.has_primary && (
                    <img
                      src={personUrl(session, p.id, 160)}
                      alt=""
                      loading="lazy"
                      style={{ width: "100%", height: "100%", objectFit: "cover" }}
                    />
                  )}
                </div>
                <div style={{ fontSize: 16, marginTop: 12 }}>{p.name}</div>
                {p.role && (
                  <div style={{ fontSize: 14, color: "var(--tv-ink-3)", marginTop: 4 }}>{p.role}</div>
                )}
              </div>
            ))}
          </div>
        </>
      )}

      {/* 页面下部原来是空的。放当前版本的规格。 */}
      <MediaInfo v={cur} />

      <Similar id={d.id} session={session} go={go} />
    </FocusColumn>
  );
}

/* ------------------------------------------------------------
   共用块
   ------------------------------------------------------------ */

/** 标题 40sp。信息块最宽 600–900dp —— 1920 屏在 3 米外的视角大小和笔记本在臂展距离差不多,
 *  要放大的只是「必须读的字」,做大只会把封面糊死。 */
function Head({ d, extra }: { d: ItemDetail; extra: string | null }) {
  const pct = d.runtime_secs > 0 ? Math.round((d.resume_secs / d.runtime_secs) * 100) : 0;
  return (
    /* 标题/评分/简介直接压在 backdrop 上,不加底也不描边(用户 2026-07-20 定)。 */
    <div style={{ maxWidth: 900 }}>
      <h3 style={{ fontSize: 40, fontWeight: 700, letterSpacing: "-.02em", margin: "0 0 10px" }}>
        {d.name}
      </h3>
      <div
        style={{
          display: "flex",
          gap: 16,
          alignItems: "center",
          fontSize: 19,
          color: "var(--tv-ink-2)",
          marginBottom: 16,
        }}
      >
        {d.rating != null && (
          <span style={{ color: "var(--accent)", fontWeight: 640 }}>★ {d.rating.toFixed(1)}</span>
        )}
        {d.year != null && <span>{d.year}</span>}
        {extra && <span>{extra}</span>}
        {d.genres.length > 0 && <span>{d.genres.slice(0, 3).join(" · ")}</span>}
        {/* 已看进度用 chip,不在 Hero 上画进度条 —— Hero 已经很满了 */}
        {pct > 0 && pct < 100 && <span style={CHIP}>已看 {pct}%</span>}
      </div>
      {d.overview && <p style={OVERVIEW}>{d.overview}</p>}
    </div>
  );
}

/** 按钮 52dp。**必须有下载和收藏** —— PC 上它们藏在右键里,TV 上没有右键。 */
function Buttons({
  d,
  target,
  session,
  go,
  label,
  version,
  picks,
}: {
  d: ItemDetail;
  /** 剧集页起播的是"下一集",电影页就是本体。 */
  target: Item | null;
  session: LoginResult;
  go: (r: Route) => void;
  label: string;
  version?: MediaVersion | null;
  /** 电影页才有(剧的层级不选版本/音轨/字幕)。 */
  picks?: Picks;
}) {
  const playId = target?.id ?? d.id;
  const resume = target ? target.resume_secs : d.resume_secs;
  const [fav, setFav] = useState(d.is_favorite);
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => setFav(d.is_favorite), [d.is_favorite]);

  const start = async (secs: number) => {
    setMsg(null);
    try {
      await play(playId, secs, version?.id ?? null);
      go({ page: "player" });
      /* ★ 落轨放在导航之后且不 await:applyPicks 要等 mpv 的 track-list 出来,
         阻塞在这儿会让按下播放到画面出现之间多卡一两秒。 */
      if (picks) void applyPicks(version ?? null, picks);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <>
      <div className="btnrow" style={{ marginBottom: 34 }}>
        <FocusItem className="btn pri fx" autoFocus onEnter={() => void start(resume > 1 ? resume : 0)}>
          <Icon n="play" className="ic ic-btn" />
          {label}
        </FocusItem>
        {resume > 1 && (
          <FocusItem className="btn fx" onEnter={() => void start(0)}>
            从头播放
          </FocusItem>
        )}
        <FocusItem
          className={`btn fx${fav ? " pri" : ""}`}
          onEnter={() => {
            const n = !fav;
            setFav(n);
            void setFavorite(d.id, n).catch(() => setFav(!n));
          }}
        >
          <Icon n="heart" className="ic ic-btn" />
          {fav ? "已收藏" : "收藏"}
        </FocusItem>
        <FocusItem
          className="btn fx"
          onEnter={() => {
            /* container 未知就传空串,核层兜成 mkv。前端瞎写扩展名会让落盘文件名跟着错。 */
            void downloadEnqueue(
              playId,
              target ? "Episode" : d.type_,
              target ? `${d.name} · ${target.name}` : d.name,
              version?.container ?? "",
              posterUrl(session, playId, 480),
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
    </>
  );
}

/** 相似推荐。空数组不是错误 —— 有些条目就是没有相似项,**整段不渲染**。 */
function Similar({
  id,
  session,
  go,
}: {
  id: string;
  session: LoginResult;
  go: (r: Route) => void;
}) {
  const { data } = useAsync(() => similarItems(id), [id]);
  if (!data || data.length === 0) return null;
  return (
    <div className="row">
      <div className="rowhead">
        <div className="t">相似推荐</div>
      </div>
      <FocusRow>
        {data.map((it) => (
          <CardPoster
            key={it.id}
            it={it}
            session={session}
            onEnter={() => go({ page: "detail", itemId: it.id })}
          />
        ))}
      </FocusRow>
    </div>
  );
}

function Note({ text }: { text: string }) {
  return (
    <div style={{ padding: "48px 64px" }}>
      <div className="psub">{text}</div>
    </div>
  );
}

const CHIP: React.CSSProperties = {
  padding: "3px 10px",
  borderRadius: 6,
  background: "rgba(255,255,255,.12)",
  fontSize: 15,
};

const OVERVIEW: React.CSSProperties = {
  fontSize: 19,
  lineHeight: 1.55,
  color: "var(--tv-ink-2)",
  margin: "0 0 24px",
  display: "-webkit-box",
  WebkitLineClamp: 3,
  WebkitBoxOrient: "vertical",
  overflow: "hidden",
};

