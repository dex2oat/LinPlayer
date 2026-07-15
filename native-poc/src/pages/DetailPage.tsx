import { useEffect, useMemo, useRef, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type LoginResult,
  type MediaVersion,
  type StreamInfo,
  backdropUrl,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  itemDetail,
  itemMedia,
  personUrl,
  posterUrl,
  setFavorite,
  thumbUrl,
} from "../lib/api";
import {
  IconChevronDown,
  IconChevronLeft,
  IconChevronRight,
  IconDownload,
  IconHeart,
  IconInfo,
  IconList,
  IconPlay,
} from "../app/icons";
import "./DetailPage.css";

type Props = {
  session: LoginResult;
  item: Item;
  onPlay: (it: Item) => void;
  onOpenChild: (it: Item) => void;
  onBack: () => void;
};

/** 哪个下拉是打开态(同一时刻只开一个)。 */
type DdKind = "line" | "ver" | "audio" | "sub" | "season" | null;

function toItem(d: ItemDetail): Item {
  return {
    id: d.id,
    name: d.name,
    type_: d.type_,
    is_folder: false,
    has_primary: d.has_primary,
    runtime_secs: d.runtime_secs,
    resume_secs: d.resume_secs,
    series_name: d.series_name,
    episode_no: d.episode_no,
    season_no: d.season_no,
    video_height: null,
    bitrate: null,
    size_bytes: null,
  };
}

/** 音轨/字幕的一行文字:服务端给了 display_title 就用它,否则自己拼。 */
function streamLabel(s: StreamInfo): string {
  if (s.display_title) return s.display_title;
  const parts =
    s.type_ === "Subtitle"
      ? [s.codec.toUpperCase(), s.language]
      : [s.codec.toUpperCase(), s.channel_layout ?? (s.channels ? `${s.channels}ch` : null), s.language];
  return parts.filter(Boolean).join(" · ") || `轨道 ${s.index}`;
}

/** 媒体信息卡的一行:没值就整行不渲染(草稿要求不出空行/undefined)。 */
function KV({ k, v }: { k: string; v: string | null | undefined }) {
  if (!v) return null;
  return (
    <div className="dt-kv">
      <span className="k">{k}</span>
      <span className="val">{v}</span>
    </div>
  );
}

/** 一张纵向流卡片(草稿 .mi;本项目改名 .dt-mi 避开 ui.css 里的右键菜单项 .mi)。 */
function MiCard({ cap, tag, children }: { cap: string; tag?: boolean; children: React.ReactNode }) {
  return (
    <div className="dt-mi">
      <div className="cap">
        {cap}
        {tag && <span className="tag">默认</span>}
      </div>
      {children}
    </div>
  );
}

export default function DetailPage({ session, item, onPlay, onOpenChild, onBack }: Props) {
  const [d, setD] = useState<ItemDetail | null>(null);
  const [err, setErr] = useState("");
  const [fav, setFav] = useState(false);
  const [expand, setExpand] = useState(false);
  const [toast, setToast] = useState("");

  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [verIdx, setVerIdx] = useState(0);
  const [audioIdx, setAudioIdx] = useState<number | null>(null);
  const [subIdx, setSubIdx] = useState<number | null>(null);
  const [dd, setDd] = useState<DdKind>(null);

  const [season, setSeason] = useState<number | null>(null);
  const [epView, setEpView] = useState<"grid" | "list">("grid");
  const [epCtx, setEpCtx] = useState<{ x: number; y: number; ep: Item } | null>(null);
  const [moreMenu, setMoreMenu] = useState<{ x: number; y: number } | null>(null);

  const clickTimer = useRef<number | null>(null);
  const railRef = useRef<HTMLDivElement | null>(null);

  const isSeries = (d?.type_ ?? item.type_) === "Series";
  const isEpisode = (d?.type_ ?? item.type_) === "Episode";

  // 详情 + 媒体信息并行发起:媒体信息只有 Movie/Episode 有(Series 自己没有 MediaSource)。
  // 媒体信息失败静默(整段不渲染),不能把整页搞红。
  useEffect(() => {
    let alive = true;
    setD(null);
    setErr("");
    setExpand(false);
    setVersions([]);
    setVerIdx(0);
    setAudioIdx(null);
    setSubIdx(null);
    setDd(null);
    setSeason(null);
    setEpCtx(null);
    setMoreMenu(null);

    itemDetail(item.id)
      .then((x) => {
        if (!alive) return;
        setD(x);
        setFav(x.is_favorite);
      })
      .catch((e) => alive && setErr(String(e)));

    if (item.type_ !== "Series") {
      itemMedia(item.id)
        .then((v) => alive && setVersions(v))
        .catch(() => {});
    }
    return () => {
      alive = false;
    };
  }, [item.id, item.type_]);

  const ver = versions[verIdx] ?? null;
  const audios = useMemo(() => ver?.streams.filter((s) => s.type_ === "Audio") ?? [], [ver]);
  const subs = useMemo(() => ver?.streams.filter((s) => s.type_ === "Subtitle") ?? [], [ver]);

  // 换版本 → 音轨/字幕回到该版本的默认轨。
  useEffect(() => {
    setAudioIdx(audios.find((s) => s.is_default)?.index ?? audios[0]?.index ?? null);
    setSubIdx(subs.find((s) => s.is_default)?.index ?? null);
  }, [audios, subs]);

  // 下拉/菜单:点外面、滚动、Esc 关(同 NetdiskPage 右键菜单套路)。
  useEffect(() => {
    if (!dd && !epCtx && !moreMenu) return;
    const close = () => {
      setDd(null);
      setEpCtx(null);
      setMoreMenu(null);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [dd, epCtx, moreMenu]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2000);
    return () => clearTimeout(t);
  }, [toast]);

  useEffect(() => () => {
    if (clickTimer.current) clearTimeout(clickTimer.current);
  }, []);

  const bgId = d?.series_id ?? item.id;
  const episodes = d?.children ?? []; // children 已按季+集号排序。

  const seasons = useMemo(() => {
    const set = new Set<number>();
    for (const e of episodes) if (e.season_no != null) set.add(e.season_no);
    return [...set].sort((a, b) => a - b);
  }, [episodes]);

  const curSeason = season ?? seasons[0] ?? null;
  const shownEps = curSeason == null ? episodes : episodes.filter((e) => e.season_no === curSeason);

  async function toggleFav() {
    const next = !fav;
    setFav(next);
    try {
      await setFavorite(item.id, next);
    } catch {
      setFav(!next);
    }
  }

  /** 播放/续播目标:剧集挑第一条有进度的,否则第一集;电影/单集就是自己。 */
  const target: Item | null = (() => {
    if (isSeries) return episodes.find((c) => c.resume_secs > 0) ?? episodes[0] ?? null;
    return d ? toItem(d) : null;
  })();

  const resumeTarget = target && target.resume_secs > 0 ? target : null;
  const playLabel = (() => {
    if (!resumeTarget) return "播放";
    const se =
      resumeTarget.season_no != null && resumeTarget.episode_no != null
        ? ` · S${resumeTarget.season_no}E${resumeTarget.episode_no}`
        : "";
    const left =
      resumeTarget.runtime_secs > 0
        ? ` · 剩余 ${fmtTime(Math.max(0, resumeTarget.runtime_secs - resumeTarget.resume_secs))}`
        : "";
    return `继续观看${se}${left}`;
  })();

  const title = isEpisode && d?.series_name ? d.series_name : d?.name ?? item.name;

  function enqueue(it: { id: string; type_: string; name: string }) {
    downloadEnqueue(it.id, it.type_, it.name, "mkv", posterUrl(session, it.id))
      .then(() => setToast("已加入下载"))
      .catch((e) => setToast(`下载失败:${e}`));
  }

  /** 媒体信息卡片区左右拖动横滑(标注 20:和 Emby 官端一致)。 */
  function dragScroll(e: React.MouseEvent<HTMLDivElement>) {
    if (e.button !== 0) return;
    const el = e.currentTarget;
    const startX = e.clientX;
    const startLeft = el.scrollLeft;
    el.classList.add("grabbing");
    const move = (ev: MouseEvent) => {
      el.scrollLeft = startLeft - (ev.clientX - startX);
      ev.preventDefault();
    };
    const up = () => {
      el.classList.remove("grabbing");
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  }

  /** 单击进详情 / 双击播放:单击延后一拍,双击来了就撤销。 */
  function epClick(ep: Item) {
    if (clickTimer.current) clearTimeout(clickTimer.current);
    clickTimer.current = window.setTimeout(() => onOpenChild(ep), 220);
  }
  function epDblClick(ep: Item) {
    if (clickTimer.current) clearTimeout(clickTimer.current);
    clickTimer.current = null;
    onPlay(ep);
  }

  const notWired = (what: string) => () => {
    setToast(`${what} — 待接`);
    setEpCtx(null);
    setMoreMenu(null);
  };

  const chev = <IconChevronDown size={12} />;

  return (
    <div className="scroll detail">
      <div className="cbody" style={{ paddingTop: 0 }}>
        {/* ① Hero:全宽出血,不受正文 max-width 约束 */}
        <div className="dt-hero">
          <img
            className="dt-hero-bg"
            src={backdropUrl(session, bgId)}
            onError={(e) => {
              const el = e.target as HTMLImageElement;
              if (item.has_primary) el.src = posterUrl(session, item.id, 720);
              else el.style.opacity = "0";
            }}
          />
          <div className="dt-hero-grad" />
          <button className="dt-hero-back" onClick={onBack} title="返回">
            <IconChevronLeft size={17} />
          </button>
          <div className="dt-hero-actions">
            <button className={`dt-ghost sm${fav ? " on" : ""}`} onClick={toggleFav} title="收藏">
              <IconHeart size={16} />
            </button>
            <button
              className="dt-ghost sm"
              title="下载"
              disabled={isSeries}
              onClick={() => d && !isSeries && enqueue(d)}
            >
              <IconDownload size={16} />
            </button>
            <button
              className="dt-ghost sm"
              title="更多"
              onClick={(e) => {
                e.stopPropagation();
                const r = e.currentTarget.getBoundingClientRect();
                setMoreMenu({ x: Math.max(8, r.right - 176), y: r.bottom + 6 });
              }}
            >
              <span className="dt-dots">
                <i />
                <i />
                <i />
              </span>
            </button>
          </div>
          <div className="dt-hero-body">
            {isEpisode && d?.episode_no != null && (
              <div className="hero-eyebrow">
                第 {d.episode_no} 集{d.name ? ` · ${d.name}` : ""}
              </div>
            )}
            <div className="dt-hero-title">{title}</div>
            <div className="chipbar dt-hero-chips">
              {d?.rating != null && <span className="genre">★ {d.rating.toFixed(1)}</span>}
              {d?.year != null && <span className="genre">{d.year}</span>}
              {d?.genres.slice(0, 3).map((g) => (
                <span className="genre" key={g}>
                  {g}
                </span>
              ))}
              {isSeries && episodes.length > 0 && <span className="genre">{episodes.length} 集</span>}
            </div>
          </div>
        </div>

        {/* 正文封顶:4K 全屏下不把内容拉成一条线、右边不死白 */}
        <div className="dt-body">
          {/* ② 大播放按钮 */}
          <div className="dt-playbar">
            {(!isSeries || episodes.length > 0) && (
              <button className="btn primary big" onClick={() => target && onPlay(target)} disabled={!target}>
                <IconPlay size={16} /> {playLabel}
              </button>
            )}
            <button className={`dt-ghost${fav ? " on" : ""}`} onClick={toggleFav} title="收藏">
              <IconHeart size={17} />
            </button>
            <button
              className="dt-ghost"
              title="下载"
              disabled={isSeries}
              onClick={() => d && !isSeries && enqueue(d)}
            >
              <IconDownload size={17} />
            </button>
            <button
              className="dt-ghost"
              title="更多"
              onClick={(e) => {
                e.stopPropagation();
                const r = e.currentTarget.getBoundingClientRect();
                setMoreMenu({ x: Math.max(8, r.left), y: r.bottom + 6 });
              }}
            >
              <span className="dt-dots">
                <i />
                <i />
                <i />
              </span>
            </button>
          </div>

          {err && <div className="empty">加载失败：{err}</div>}

          {/* ③ 简介 */}
          {d?.overview && (
            <>
              <div className="rowlab" style={{ margin: "20px 0 10px" }}>
                <span className="h">简介</span>
              </div>
              <p className={`dt-overview${expand ? "" : " clamp"}`}>{d.overview}</p>
              {d.overview.length > 120 && (
                <button className="dt-expand" onClick={() => setExpand((v) => !v)}>
                  {expand ? "收起" : "展开"} {chev}
                </button>
              )}
            </>
          )}

          {/* ④ 选择器:线路 / 版本 / 音轨 / 字幕(Series 无 MediaSource → 整段不渲染) */}
          {!isSeries && versions.length > 0 && (
            <div className="dt-selrow" style={{ marginTop: 16 }}>
              {/* 线路:多线路是服务器级功能,核层没有 → 只列主线,诚实标注 */}
              <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                <span className={`sel${dd === "line" ? " on" : ""}`} onClick={() => setDd(dd === "line" ? null : "line")}>
                  线路 · 主线 {chev}
                </span>
                {dd === "line" && (
                  <div className="dd">
                    <div className="li on">
                      <span className="rad" />
                      主线
                    </div>
                    <div className="caption-note" style={{ padding: "4px 9px 2px", margin: 0 }}>
                      多线路待接
                    </div>
                  </div>
                )}
              </span>

              {/* 版本:真数据。>1 个版本时按草稿 776 行用 accent 边框标当前生效项 */}
              <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                <span
                  className={`sel${dd === "ver" ? " on" : ""}`}
                  style={versions.length > 1 ? { borderColor: "var(--accent)", color: "var(--ink)" } : undefined}
                  onClick={() => setDd(dd === "ver" ? null : "ver")}
                >
                  版本 · {ver?.name ?? "—"} {chev}
                </span>
                {dd === "ver" && (
                  <div className="dd">
                    {versions.map((v, i) => (
                      <div
                        key={v.id}
                        className={`li${i === verIdx ? " on" : ""}`}
                        onClick={() => {
                          setVerIdx(i);
                          setDd(null);
                        }}
                      >
                        <span className="rad" />
                        {v.name}
                        <span className="rt">{fmtSize(v.size_bytes)}</span>
                      </div>
                    ))}
                    <div className="caption-note" style={{ padding: "4px 9px 2px", margin: 0 }}>
                      选择暂不回传播放器,待接
                    </div>
                  </div>
                )}
              </span>

              {/* 音轨:选中版本的 Audio 流 */}
              {audios.length > 0 && (
                <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                  <span
                    className={`sel${dd === "audio" ? " on" : ""}`}
                    onClick={() => setDd(dd === "audio" ? null : "audio")}
                  >
                    音轨 · {audios.find((s) => s.index === audioIdx) ? streamLabel(audios.find((s) => s.index === audioIdx)!) : "—"} {chev}
                  </span>
                  {dd === "audio" && (
                    <div className="dd">
                      {audios.map((s) => (
                        <div
                          key={s.index}
                          className={`li${s.index === audioIdx ? " on" : ""}`}
                          onClick={() => {
                            setAudioIdx(s.index);
                            setDd(null);
                          }}
                        >
                          <span className="rad" />
                          {streamLabel(s)}
                          {fmtBitrate(s.bitrate) && <span className="rt">{fmtBitrate(s.bitrate)}</span>}
                        </div>
                      ))}
                      <div className="caption-note" style={{ padding: "4px 9px 2px", margin: 0 }}>
                        选择暂不回传播放器,待接
                      </div>
                    </div>
                  )}
                </span>
              )}

              {/* 字幕:选中版本的 Subtitle 流 + 关闭字幕 */}
              <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                <span className={`sel${dd === "sub" ? " on" : ""}`} onClick={() => setDd(dd === "sub" ? null : "sub")}>
                  {/* 换版本时本帧 subIdx 可能还是旧版本的 → 查不到就按「关闭」显示,等 effect 校正 */}
                  字幕 · {subs.find((s) => s.index === subIdx) ? streamLabel(subs.find((s) => s.index === subIdx)!) : "关闭"} {chev}
                </span>
                {dd === "sub" && (
                  <div className="dd">
                    {subs.map((s) => (
                      <div
                        key={s.index}
                        className={`li${s.index === subIdx ? " on" : ""}`}
                        onClick={() => {
                          setSubIdx(s.index);
                          setDd(null);
                        }}
                      >
                        <span className="rad" />
                        {streamLabel(s)}
                      </div>
                    ))}
                    <div
                      className={`li${subIdx == null ? " on" : ""}`}
                      onClick={() => {
                        setSubIdx(null);
                        setDd(null);
                      }}
                    >
                      <span className="rad" />
                      关闭字幕
                    </div>
                    <div className="caption-note" style={{ padding: "4px 9px 2px", margin: 0 }}>
                      选择暂不回传播放器,待接
                    </div>
                  </div>
                )}
              </span>
            </div>
          )}

          {/* ⑤ 分集:季用下拉切换(标注 15),右侧网格/列表切换 */}
          {isSeries && episodes.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "24px 0 10px" }}>
                <span className="h">分集</span>
                {seasons.length > 1 && (
                  <span className="dt-selwrap" style={{ marginLeft: 4 }} onClick={(e) => e.stopPropagation()}>
                    <span
                      className={`sel${dd === "season" ? " on" : ""}`}
                      onClick={() => setDd(dd === "season" ? null : "season")}
                    >
                      第 {curSeason} 季 {chev}
                    </span>
                    {dd === "season" && (
                      <div className="dd">
                        {seasons.map((s) => (
                          <div
                            key={s}
                            className={`li${s === curSeason ? " on" : ""}`}
                            onClick={() => {
                              setSeason(s);
                              setDd(null);
                            }}
                          >
                            <span className="rad" />第 {s} 季
                            <span className="rt">{episodes.filter((e) => e.season_no === s).length} 集</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </span>
                )}
                <span className="all dt-viewtoggle">
                  <button
                    className={epView === "grid" ? "on" : ""}
                    title="网格"
                    onClick={() => setEpView("grid")}
                  >
                    <span className="dt-gridic">
                      <i />
                      <i />
                      <i />
                      <i />
                    </span>
                  </button>
                  <button className={epView === "list" ? "on" : ""} title="列表" onClick={() => setEpView("list")}>
                    <IconList size={14} />
                  </button>
                </span>
              </div>
              <div className={`dt-epgrid${epView === "list" ? " list" : ""}`}>
                {shownEps.map((ep) => {
                  const prog =
                    ep.resume_secs > 0 && ep.runtime_secs > 0
                      ? Math.min(100, (ep.resume_secs / ep.runtime_secs) * 100)
                      : 0;
                  // 标注 16:分集卡一行 mono 小字「2160p · 45M · 18.4G」,缺项跳过。
                  const meta = [fmtRes(ep.video_height), fmtBitrate(ep.bitrate), fmtSize(ep.size_bytes)]
                    .filter(Boolean)
                    .join(" · ");
                  return (
                    <div
                      className="dt-ep"
                      key={ep.id}
                      onClick={() => epClick(ep)}
                      onDoubleClick={() => epDblClick(ep)}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        setEpCtx({ x: e.clientX, y: e.clientY, ep });
                      }}
                    >
                      <div className="th">
                        {ep.has_primary ? (
                          <img
                            src={thumbUrl(session, ep.id, 320)}
                            loading="lazy"
                            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
                          />
                        ) : (
                          <IconPlay size={18} />
                        )}
                        {prog > 0 && (
                          <div className="progress">
                            <i style={{ width: `${prog}%` }} />
                          </div>
                        )}
                        {/* 标注 16:悬停显现播放 */}
                        <button
                          className="dt-ep-play"
                          title="播放"
                          onClick={(e) => {
                            e.stopPropagation();
                            if (clickTimer.current) clearTimeout(clickTimer.current);
                            onPlay(ep);
                          }}
                        >
                          <IconPlay size={14} />
                        </button>
                      </div>
                      <div className="lines">
                        <div className="en">{ep.name}</div>
                        {meta && <div className="em">{meta}</div>}
                        {!meta && ep.runtime_secs > 0 && <div className="em">{fmtTime(ep.runtime_secs)}</div>}
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}

          {/* ⑥ 演职人员(真数据,没有就整段不渲染) */}
          {d && d.people.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "18px 0 8px" }}>
                <span className="h">演职人员</span>
              </div>
              <div className="dt-castwrap">
                <div className="rail dt-castrail" ref={railRef}>
                  {d.people.map((p) => (
                    <div className="dt-cast" key={p.id + p.type_ + (p.role ?? "")} title={p.role ?? p.type_}>
                      <div className="av">
                        {p.has_primary ? (
                          <img
                            src={personUrl(session, p.id)}
                            loading="lazy"
                            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
                          />
                        ) : (
                          <span className="ini">{p.name.slice(0, 1)}</span>
                        )}
                      </div>
                      <div className="cn">{p.name}</div>
                      <div className="cr">{p.role ?? p.type_}</div>
                    </div>
                  ))}
                </div>
                <button
                  className="dt-railarrow"
                  title="更多"
                  onClick={() => railRef.current?.scrollBy({ left: 300, behavior: "smooth" })}
                >
                  <IconChevronRight size={16} />
                </button>
              </div>
            </>
          )}

          {/* ⑦ 媒体信息:每个版本一整块,流卡片全部铺开(标注 20) */}
          {versions.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "26px 0 8px" }}>
                <span className="h">媒体信息</span>
                <span className="all" style={{ cursor: "default" }}>
                  每个版本一整块,流卡片全部铺开 · 无需点击
                </span>
              </div>
              {versions.map((v, i) => {
                const vid = v.streams.find((s) => s.type_ === "Video") ?? null;
                const va = v.streams.filter((s) => s.type_ === "Audio");
                const vs = v.streams.filter((s) => s.type_ === "Subtitle");
                return (
                  <div className="dt-ver-block" key={v.id}>
                    <div className="dt-ver-head">
                      <span className="nm">
                        版本 {i + 1} · {v.name}
                      </span>
                      <span className="badges chipbar">
                        {v.container && <span className="genre">{v.container.toUpperCase()}</span>}
                        {fmtSize(v.size_bytes) && <span className="genre">{fmtSize(v.size_bytes)}</span>}
                        {fmtRes(vid?.height ?? null) && <span className="genre">{fmtRes(vid?.height ?? null)}</span>}
                        {vid?.video_range && <span className="genre">{vid.video_range}</span>}
                      </span>
                    </div>
                    <div className="dt-ver-cards" onMouseDown={dragScroll}>
                      {vid && (
                        <MiCard cap="视频">
                          <KV k="编码" v={[vid.codec.toUpperCase(), vid.profile].filter(Boolean).join(" · ")} />
                          <KV k="分辨率" v={vid.width && vid.height ? `${vid.width}×${vid.height}` : null} />
                          <KV k="动态范围" v={vid.video_range} />
                          <KV k="帧率" v={vid.frame_rate ? vid.frame_rate.toFixed(3) : null} />
                          <KV k="码率" v={fmtBitrate(vid.bitrate)} />
                        </MiCard>
                      )}
                      {va.map((s, n) => (
                        <MiCard key={s.index} cap={`音频 ${n + 1}`} tag={s.is_default}>
                          <KV k="编码" v={s.codec.toUpperCase()} />
                          <KV k="声道" v={s.channel_layout ?? (s.channels ? String(s.channels) : null)} />
                          <KV k="语言" v={s.language} />
                          <KV k="码率" v={fmtBitrate(s.bitrate)} />
                        </MiCard>
                      ))}
                      {vs.map((s, n) => (
                        <MiCard key={s.index} cap={`字幕 ${n + 1}`} tag={s.is_default}>
                          <KV k="格式" v={s.codec.toUpperCase()} />
                          <KV k="语言" v={s.language} />
                        </MiCard>
                      ))}
                      <MiCard cap="常规">
                        <KV k="容器" v={v.container?.toUpperCase()} />
                        <KV k="大小" v={fmtSize(v.size_bytes)} />
                        <KV k="时长" v={v.runtime_secs > 0 ? fmtTime(v.runtime_secs) : null} />
                        <KV k="总码率" v={fmtBitrate(v.bitrate)} />
                      </MiCard>
                    </div>
                  </div>
                );
              })}
            </>
          )}
        </div>
        <div style={{ height: 40 }} />
      </div>

      {/* Hero/播放条的「更多」锚定菜单(标注 13) */}
      {moreMenu && (
        <div className="ctxmenu" style={{ left: moreMenu.x, top: moreMenu.y }} onClick={(e) => e.stopPropagation()}>
          <div className="mi" onClick={notWired("投屏")}>
            <IconInfo size={15} /> 投屏
          </div>
          <div className="mi" onClick={notWired("换源")}>
            <IconInfo size={15} /> 换源
          </div>
          <div className="mi" onClick={notWired("标记已看")}>
            <IconInfo size={15} /> 标记已看
          </div>
          <div className="mi" onClick={notWired("外部 MPV 打开")}>
            <IconInfo size={15} /> 外部 MPV 打开
          </div>
        </div>
      )}

      {/* 分集右键菜单(标注 16) */}
      {epCtx && (
        <div className="ctxmenu" style={{ left: epCtx.x, top: epCtx.y }} onClick={(e) => e.stopPropagation()}>
          <div className="mi" onClick={notWired("标记已看")}>
            <IconInfo size={15} /> 标记已看
          </div>
          <div className="mi" onClick={notWired("标记未看")}>
            <IconInfo size={15} /> 标记未看
          </div>
          <div
            className="mi"
            onClick={() => {
              enqueue(epCtx.ep);
              setEpCtx(null);
            }}
          >
            <IconDownload size={15} /> 下载本集
          </div>
          <div className="mi" onClick={notWired("换源")}>
            <IconInfo size={15} /> 换源
          </div>
        </div>
      )}

      {toast && <div className="toast">{toast}</div>}
    </div>
  );
}
