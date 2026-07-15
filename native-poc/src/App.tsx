import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  type AccountInfo,
  type DanmakuEpisode,
  type DanmakuMatchCandidate,
  type DanmakuMatchInput,
  type DanmakuSourceGroup,
  type DownloadItem,
  type Item,
  type LineProbe,
  type LoginResult,
  type MediaVersion,
  type Prefs,
  type SourceEntry,
  type Status,
  type Track,
  addSubtitle,
  applyPrefs,
  currentSession,
  danmakuAutoLoad,
  danmakuLoad,
  danmakuMatch,
  danmakuMinAutoScore,
  danmakuSearch,
  defaultDanmakuFilter,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  getPrefs,
  itemDetail,
  itemMedia,
  listAccounts,
  play,
  playLocal,
  playerOpts,
  posterUrl,
  probeLines,
  reportProgress,
  screenshot,
  seek as seekApi,
  setActiveLine,
  setAspectRatio as setAspectRatioApi,
  setAudioDelay,
  setHwdec as setHwdecApi,
  setMute as setMuteApi,
  setPause,
  setPrefs,
  setSecondarySub,
  setSecondarySubOpts,
  setShaderLevel,
  setSpeed as setSpeedApi,
  setSubDelay,
  setSubStyle,
  setTrack,
  setVolume as setVolumeApi,
  shaderLevels,
  sourcePlay,
  sourceWatchdog,
  status as statusApi,
  stopPlayback,
  tracks as tracksApi,
} from "./lib/api";
import { DanmakuLayer, type DanmakuComment, type TimeSync } from "./Danmaku";
import LoginPage from "./pages/LoginPage";
import Shell from "./app/Shell";
import {
  IconChevronLeft,
  IconForward,
  IconFullscreen,
  IconInfo,
  IconList,
  IconNext,
  IconPause,
  IconPlay,
  IconPrev,
  IconRefresh,
  IconRewind,
  IconSun,
  IconVolume,
} from "./app/icons";
import "./theme/tokens.css";
import "./theme/ui.css";
import "./theme/player.css";

type Panel = null | "eps" | "audio" | "sub" | "danmaku" | "super" | "line" | "version" | "speed" | "more";
/** 竖条弹出态:kind 决定调音量还是亮度,x 是按钮中心(贴着按钮弹,草稿 21)。 */
type VBar = null | { kind: "vol" | "bright"; x: number };

/** 草稿倍速面板「常用」档位。 */
const SPEEDS = [0.5, 1.0, 1.5, 2.0, 3.0];
/** 弹幕显示区域档位 → 占屏高百分比(草稿 stepper「1/2 屏」)。 */
const DM_AREAS = [25, 50, 75, 100];
/* 弹幕「显示速度 / 字体大小」是前端渲染参数(核层 danmaku_filter 文档写明渲染归前端),
   不是缺核层命令 —— 档位在这儿定,值透传给 DanmakuLayer 的 duration / fontSize props。
   两张表的默认下标(DM_DEFAULT)都对着组件原本写死的常量,不动档位 = 观感与以前一模一样。 */
/** 滚动弹幕横穿屏幕的秒数(越小越快)。「中」=8s = Danmaku.tsx 的 DURATION。 */
const DM_SPEEDS: [number, string][] = [[14, "极慢"], [11, "慢"], [8, "中"], [6, "快"], [4.5, "极快"]];
/** 弹幕字号(CSS px);null =「按画面高自适应」,即组件不传 fontSize 时的原行为。 */
const DM_SIZES: [number | null, string][] = [[16, "极小"], [20, "小"], [null, "中"], [28, "大"], [34, "极大"]];
const DM_DEFAULT = 2; // 两张表的「中」都在下标 2
/** 解码档位 → mpv hwdec 值。零拷贝(d3d11va)是 Win 最佳,软解(no)排查用。 */
const HWDECS: [string, string][] = [["auto-safe", "硬解"], ["d3d11va", "零拷贝"], ["no", "软解"]];
/** 定时关闭档位(分钟)。照搬旧 Flutter 端既有档位(player_screen_state _showTimerDialog),不另造一套。 */
const SLEEP_MINS = [15, 30, 45, 60, 90, 120];
/** 画面比例档位 → mpv video-aspect-override("" = 还原源比例)。 */
const ASPECTS: [string, string][] = [
  ["", "原始"], ["16:9", "16:9"], ["4:3", "4:3"], ["1.85", "1.85:1"], ["2.35", "2.35:1"], ["21:9", "21:9"],
];
/** 字幕字体档位。「默认」不能传字面量(核层守卫会当占位跳过),故映射到 mpv 真默认 sans-serif。 */
const SUB_FONTS: [string, string][] = [
  ["sans-serif", "默认"], ["Microsoft YaHei", "微软雅黑"], ["Noto Sans CJK SC", "思源黑体"],
  ["SimHei", "黑体"], ["KaiTi", "楷体"],
];
/** 延迟显示:带符号一位小数,0 也显示 0.0s 免得以为没接上。 */
const fmtDelay = (s: number) => `${s > 0 ? "+" : ""}${s.toFixed(1)}s`;
/** 浮点步进会攒出 0.30000000000000004,统一钉到一位小数。 */
const round1 = (v: number) => Math.round(v * 10) / 10;
/** hwdec-current 回读的是实际解码器(如 d3d11va-copy),归一到三档才好高亮。 */
const normHwdec = (h: string) => (!h || h === "no" ? "no" : h.startsWith("d3d11") ? "d3d11va" : "auto-safe");

export default function App() {
  const [booted, setBooted] = useState(false);
  const [session, setSession] = useState<LoginResult | null>(null);
  const [searchOpen, setSearchOpen] = useState(false);

  const [playing, setPlaying] = useState<Item | null>(null);
  const [status, setStatus] = useState<Status>({ time: 0, duration: 0, paused: false, buffered: 0 });
  const [tracks, setTracks] = useState<Track[]>([]);
  const [prefs, setPrefs2] = useState<Prefs>({ audio_lang: null, sub_lang: null, sub_enabled: true });
  const [seeking, setSeeking] = useState<number | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [idle, setIdle] = useState(false);
  const timer = useRef<number | null>(null);
  const tick = useRef(0);
  const idleTimer = useRef<number | null>(null);

  // 播放器 OSD 态
  const [siblings, setSiblings] = useState<Item[]>([]); // 当前剧全部分集(上/下一集 + 选集)
  const [versions, setVersions] = useState<MediaVersion[] | null>(null); // 版本面板(item_media)
  const [curMsId, setCurMsId] = useState<string | null>(null); // 当前在播的 media_source_id(版本高亮的真依据)
  // 线路面板(probe_lines / set_active_line 都真接)
  const [lineProbes, setLineProbes] = useState<LineProbe[] | null>(null);
  const [acct, setAcct] = useState<AccountInfo | null>(null);
  const [lineErr, setLineErr] = useState<string | null>(null);
  const [vbar, setVbar] = useState<VBar>(null);
  const [volume, setVol] = useState(70); // 真接 set_volume;起播后由 player_opts 覆盖成真值
  const [muted, setMuted] = useState(false);
  const [brightness, setBrightness] = useState(100); // 纯前端黑遮罩,真生效

  // 播放器可调项:初值都是占位,起播后 player_opts() 拉真值覆盖(否则滑块位置是假的)
  const [speed, setSpd] = useState(1);
  /* 长按连调的 interval 里拿不到 speed state 的最新值(闭包快照的是按下那刻的),
     故 applySpeed 同步往这份 ref 记一手,连调只读 ref。 */
  const speedRef = useRef(1);
  const [aDelay, setADelay] = useState(0);
  const [sDelay, setSDelay] = useState(0);
  const [hwdec, setHw] = useState("auto-safe");
  const [aspect, setAspect] = useState("");
  const [arOpen, setArOpen] = useState(false);
  // 超分:档位清单来自核层 shader_levels(),不再前端写死
  const [shaderList, setShaderList] = useState<[string, string][]>([]);
  const [shaderLv, setShaderLv] = useState("off");
  // 字幕样式:核层无回读命令,故记前端态;初值取 mpv 自身默认(sub-font-size 55 / sub-pos 100)
  const [subFont, setSubFont] = useState("sans-serif");
  const [fontOpen, setFontOpen] = useState(false);
  const [subSize, setSubSize] = useState(55);
  const [subPos, setSubPos] = useState(100);
  const [sec2, setSec2] = useState(""); // 次字幕 sid,"" = 关
  const [sec2Delay, setSec2Delay] = useState(0);
  const [sec2Pos, setSec2Pos] = useState(100);
  const [subUrl, setSubUrl] = useState<string | null>(null); // 非 null = 外挂字幕输入框已展开
  // 定时关闭:纯前端,不需要核层命令。句柄必须放 ref —— 放 state 重渲染就丢了句柄,到点没人清。
  const [sleepMin, setSleepMin] = useState<number | null>(null); // null = 关闭
  const [sleepOpen, setSleepOpen] = useState(false);
  const sleepTimer = useRef<number | null>(null);
  const [dolby, setDolby] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [ctx, setCtx] = useState<{ x: number; y: number } | null>(null);
  const [marquee, setMarquee] = useState(false);
  const titleRef = useRef<HTMLSpanElement>(null);
  const toastTimer = useRef<number | null>(null);

  // 弹幕。源的增删改查在设置页(多源 CRUD),这儿只管「搜索 / 选源 / 显示」(草稿 L1119)。
  const [dmComments, setDmComments] = useState<DanmakuComment[]>([]);
  const [dmOn, setDmOn] = useState(false);
  const [dmResults, setDmResults] = useState<DanmakuSourceGroup[] | null>(null);
  const [dmKw, setDmKw] = useState("");
  const [dmOpacity, setDmOpacity] = useState(80); // 纯 CSS,真生效
  const [dmArea, setDmArea] = useState(1); // DM_AREAS 下标,纯 CSS 裁剪,真生效
  const [dmSpeed, setDmSpeed] = useState(DM_DEFAULT); // DM_SPEEDS 下标 → DanmakuLayer duration
  const [dmSize, setDmSize] = useState(DM_DEFAULT); // DM_SIZES 下标 → DanmakuLayer fontSize
  const timeSync = useRef<TimeSync>({ base: 0, stamp: performance.now(), paused: false });

  // 进度条悬停时间气泡(草稿 pin 18);x 是条内像素偏移。
  const [hoverT, setHoverT] = useState<{ x: number; t: number } | null>(null);

  /* 长按 +/− 连调的句柄。必须放 ref —— 放 state 一重渲染就换了新值,松手时 clear 的是旧句柄,
     结果按一次停不下来,一路调到底。 */
  const repeat = useRef<number | null>(null);

  useEffect(() => {
    (async () => {
      const s = await currentSession().catch(() => null);
      if (s) setSession(s);
      getPrefs().then(setPrefs2).catch(() => {});
      /* 这里原本 invoke<DmConfig>("get_danmaku_config") 把 Vec<DanmakuServer> 读成单对象
         (api_url 恒 undefined),而弹幕源的增删改现已归设置页 —— 播放器不需要读它,直接删。
         真要读请走 api.ts 的 getDanmakuConfig(): DanmakuServer[],别再退回单对象。 */
      // 超分档位是核层静态清单(不依赖播放器),开机拉一次即可。
      shaderLevels().then(setShaderList).catch(() => {});
      setBooted(true);
    })();
  }, []);

  // 全局 Ctrl+K 唤起搜索。
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        if (session && !playing) setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [session, playing]);

  const trackLang = (list: Track[], id: string) => list.find((t) => t.id === id)?.lang || "";
  async function persistPrefs(next: Prefs) {
    setPrefs2(next);
    await setPrefs(next).catch(() => {});
  }

  /** OSD 统一提示(复用 ui.css 的 .toast)。
      停留时长按字数给:整句解释(如超分为何不生效)2.4s 根本读不完,读不完等于没说。 */
  function say(msg: string) {
    setToast(msg);
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    const ms = Math.min(9000, Math.max(2400, msg.length * 130));
    toastTimer.current = window.setTimeout(() => setToast(null), ms);
  }
  /** 核层确实没有的命令:诚实告知,不装作能用。 */
  const soon = (what: string) => say(`${what}:核层暂无对应命令,待接`);
  /** 真调用失败一律如实说,不静默吞(尤其超分:吞掉就成了「以为开了其实没开」)。 */
  const fail = (what: string, e: unknown) => say(`${what}失败:${e}`);

  /* 弹幕自动匹配。核层的 danmaku_auto_load 是一整套(多源并行 + 分数门槛 + 下一集锚点快路径),
     以前 afterStart 只 setDmKw 就完事,等于把这套子系统整个晾着,用户每集都得手搜一遍。
     anchor_key 传剧 id:核层据此走「紧邻上一集的下一集」快路径,省掉一整轮全网匹配。
     全程 catch:弹幕挂不上绝不能反向污染起播链路 —— 但也绝不静默,退化成手动挑并说清原因
     (弹幕最常见的失败是「没配源」,吞掉的话用户只会看见弹幕莫名其妙不出来)。 */
  async function autoDanmaku(it: Item) {
    const input: DanmakuMatchInput = {
      title: it.series_name ?? it.name, // 剧集要用剧名,Episode.name 是「第 35 集」搜不到
      episode_no: it.episode_no,
      file_name: it.name,
      duration_secs: it.runtime_secs > 0 ? it.runtime_secs : null,
    };
    try {
      const auto = await danmakuAutoLoad(input, defaultDanmakuFilter(), null, it.series_id ?? null);
      if (auto) { setDmComments(auto); setDmOn(true); return; } // 够可信 → 静默挂上,不打扰
      // null = 核层认为没有够格自动挂的匹配。再看一眼候选:够门槛就挂,不够就把面板留给用户。
      const cands = await danmakuMatch(input);
      const top = cands.reduce<DanmakuMatchCandidate | null>((a, b) => (!a || b.score > a.score ? b : a), null);
      if (top && top.score >= (await danmakuMinAutoScore())) {
        setDmComments(await danmakuLoad(top.episode_id));
        setDmOn(true);
        say(`弹幕已自动匹配 · ${top.source_name} · ${top.anime_title}`);
        return;
      }
      say(cands.length ? "弹幕候选可信度不足,请在弹幕面板手动挑选" : "未找到匹配的弹幕,可在弹幕面板手动搜索");
    } catch (e) {
      say(`弹幕自动匹配失败:${e} · 可在弹幕面板手动搜索`);
    }
  }

  async function afterStart(it: Item) {
    setDmComments([]);
    setDmOn(false);
    setDmKw(it.series_name ?? it.name); // 手搜的预填也用剧名,和自动匹配同一口径
    setDmResults(null);
    setPanel(null);
    setVersions(null);
    // 换片重置前端侧样式态(核层是新播放器实例,旧的延迟/次字幕都没了)。
    setSubUrl(null);
    setADelay(0); setSDelay(0);
    setSec2(""); setSec2Delay(0); setSec2Pos(100);
    setSubSize(55); setSubPos(100); setSubFont("sans-serif");
    setAspect(""); setShaderLv("off");
    setSleepMin(null); setSleepOpen(false); setDolby(false); // 定时句柄由 [playing] 的 cleanup 清
    autoDanmaku(it); // 不 await:弹幕匹配要打网络,不能拖住起播后的 OSD 初始化
    setTimeout(async () => {
      await applyPrefs().catch(() => {});
      setTracks(await tracksApi().catch(() => []));
      // 音量/倍速/静音/延迟/解码拉真值 —— 否则 OSD 滑块显示的是前端瞎猜的初值。
      try {
        const o = await playerOpts();
        setVol(Math.round(o.volume));
        setMuted(o.muted);
        setSpd(o.speed);
        speedRef.current = o.speed; // 连调基准也得跟着回读的真值走,否则长按会从 1.0 起跳
        setADelay(round1(o.audio_delay));
        setSDelay(round1(o.sub_delay));
        setHw(normHwdec(o.hwdec));
        setShaderLv((lv) => (o.shader_count > 0 ? lv : "off"));
      } catch { /* 播放器未就绪:保持占位值,不弹错打扰起播 */ }
    }, 1200);
  }

  /** mediaSourceId = 详情页版本选择器选中的版本;省略 = 服务端给的第一个。
      ★ 这个第二参必须一路透传到 play():少了它,用户在详情页选了 4K 起播仍是
      默认版本,且**不报错** —— TS 上少参函数可赋给多参形参,编译期抓不到。 */
  async function playItem(it: Item, mediaSourceId?: string | null) {
    try {
      const resume = await play(it.id, it.resume_secs, mediaSourceId ?? null);
      setPlaying(it);
      // 版本:详情页指定了就照它高亮,否则等 item_media 回来按服务端第一个初始化。
      setCurMsId(mediaSourceId ?? null);
      setStatus({ time: resume, duration: it.runtime_secs, paused: false, buffered: 0 });
      afterStart(it);
    } catch (e) {
      alert(String(e));
    }
  }

  /** 播放已下载完成的本地文件(下载页 ▶ / 双击)。
      必须由 App 起播:mpv 的视频窗口压在 Tauri 窗口之下,只有 setPlaying 触发的
      .app-root.hidden 才让它露出来 —— 页面自己调 playLocal 只会有声音没画面。 */
  async function playDownload(d: DownloadItem) {
    try {
      const resume = await playLocal(d.id, 0);
      const synth: Item = {
        id: d.item_id || d.id, name: d.title, type_: "Video", is_folder: false, has_primary: false,
        runtime_secs: 0, resume_secs: resume, series_name: d.series_name, episode_no: d.episode_number,
        season_no: d.season_number, video_height: null, bitrate: null, size_bytes: d.total_bytes,
        played: false, genres: [], year: null, rating: null, provider_ids: {},
        presentation_unique_key: null, path: d.file_path, series_id: d.series_id,
      };
      setPlaying(synth);
      setCurMsId(null);
      setStatus({ time: resume, duration: 0, paused: false, buffered: 0 });
      afterStart(synth);
    } catch (e) {
      alert(String(e));
    }
  }

  async function playSource(entry: SourceEntry) {
    try {
      const start = await sourcePlay(entry, 0);
      // 网盘文件不是 Emby 条目:剧集号/规格字段一律 null。
      const synth: Item = { id: entry.id, name: entry.name, type_: "Video", is_folder: false, has_primary: false, runtime_secs: 0, resume_secs: 0, series_name: null, episode_no: null, season_no: null, video_height: null, bitrate: null, size_bytes: null, played: false, genres: [], year: null, rating: null, provider_ids: {}, presentation_unique_key: null, path: null, series_id: null };
      setPlaying(synth);
      setCurMsId(null);
      setStatus({ time: start, duration: 0, paused: false, buffered: 0 });
      afterStart(synth);
    } catch (e) {
      alert(String(e));
    }
  }

  async function refreshSession() {
    const s = await currentSession().catch(() => null);
    setSession(s);
  }

  async function togglePause() {
    const p = !status.paused;
    await setPause(p).catch(() => {});
    setStatus((s) => ({ ...s, paused: p }));
    reportProgress(status.time, p);
  }
  const doSeek = (t: number) => { const v = Math.max(0, Math.min(status.duration || t, t)); seekApi(v); setStatus((s) => ({ ...s, time: v })); };

  async function closePlayer() {
    await stopPlayback(status.time);
    setPlaying(null);
    setTracks([]);
    setPanel(null);
    setVbar(null);
    setCtx(null);
    setSiblings([]);
    setBrightness(100);
  }

  async function toggleFullscreen() {
    try {
      const w = getCurrentWindow();
      await w.setFullscreen(!(await w.isFullscreen()));
    } catch { /* 忽略 */ }
  }
  async function exitFullscreen() {
    try {
      const w = getCurrentWindow();
      if (await w.isFullscreen()) await w.setFullscreen(false);
    } catch { /* 忽略 */ }
  }

  useEffect(() => {
    if (!playing) {
      if (timer.current) window.clearInterval(timer.current);
      return;
    }
    tick.current = 0;
    timer.current = window.setInterval(async () => {
      try {
        const st = await statusApi();
        setStatus(st);
        timeSync.current = { base: st.time, stamp: performance.now(), paused: st.paused };
        tick.current++;
        if (tick.current % 10 === 0) reportProgress(st.time, st.paused);
        sourceWatchdog(st.time);
      } catch { /* 未就绪忽略 */ }
    }, 500);
    return () => { if (timer.current) window.clearInterval(timer.current); };
  }, [playing]);

  /* 定时关闭的兜底清理:换片/退播放器/组件卸载都必须 clearTimeout,
     否则播放器都关了它还在后台跑,到点 closePlayer 一个不存在的播放器。 */
  useEffect(() => {
    return () => {
      if (sleepTimer.current) { window.clearTimeout(sleepTimer.current); sleepTimer.current = null; }
    };
  }, [playing]);

  // OSD 自动隐藏(鼠标静止 3s)。
  useEffect(() => {
    if (!playing) return;
    const wake = () => {
      setIdle(false);
      if (idleTimer.current) window.clearTimeout(idleTimer.current);
      idleTimer.current = window.setTimeout(() => setIdle(true), 3000);
    };
    wake();
    window.addEventListener("mousemove", wake);
    return () => { window.removeEventListener("mousemove", wake); if (idleTimer.current) window.clearTimeout(idleTimer.current); };
  }, [playing]);

  /* 拉当前剧的分集列表(上一集/下一集/选集全靠它)。
     Item 本身没有 series_id,但 item_detail(集) 会回 series_id,
     再 item_detail(剧) 的 children 就是按季+集号排好序的全部分集(且带 MediaSources 规格)。 */
  useEffect(() => {
    if (!playing || playing.type_ !== "Episode") { setSiblings([]); return; }
    let dead = false;
    (async () => {
      try {
        const ep = await itemDetail(playing.id);
        if (dead || !ep.series_id) return;
        const series = await itemDetail(ep.series_id);
        if (!dead) setSiblings(series.children);
      } catch { /* 网盘/非 Emby 条目没有剧集树,静默 */ }
    })();
    return () => { dead = true; };
  }, [playing]);

  // 版本面板用的 MediaSources:开面板时才拉,省一次请求。
  useEffect(() => {
    if (panel !== "version" || !playing || versions) return;
    itemMedia(playing.id)
      .then((vs) => {
        setVersions(vs);
        // play() 不传 mediaSourceId 时核层用服务端给的第一个,故没切过版本时就高亮它。
        // 以前这里写死 i===0,切完版本高亮还赖在第一行 —— 别再用下标当选中态。
        setCurMsId((id) => id ?? vs[0]?.id ?? null);
      })
      .catch(() => setVersions([]));
  }, [panel, playing, versions]);

  /* 线路探测。★ server_id 是**账号键**(list_accounts().server),不是 session.server:
     set_active_line 切完会把 session.server 改写成那条线路的 URL,此后 session.server
     就不再等于账号键,再拿它去 probe_lines 只会得到「找不到该服务器」。踩过,别改回去。
     草稿 L1037 要求「进入服务器自动探测 · 缓存至退出程序清空」→ 探到就存着不重探。 */
  useEffect(() => {
    if (panel !== "line" || lineProbes) return;
    let dead = false;
    (async () => {
      try {
        const a = (await listAccounts()).find((x) => x.active);
        if (dead) return;
        if (!a) { setLineErr("没有活跃的服务器账号"); return; }
        setAcct(a);
        setLineErr(null);
        setLineProbes(await probeLines(a.server)); // ← a.server = 账号键
      } catch (e) {
        if (!dead) setLineErr(String(e));
      }
    })();
    return () => { dead = true; };
  }, [panel, lineProbes]);

  /** 切线路:立即生效无需重启(核层会同步刷新活跃会话地址)。 */
  async function switchLine(index: number) {
    if (!acct) return;
    try {
      await setActiveLine(acct.server, index); // 同上:必须是账号键
      setAcct({ ...acct, active_line: index });
      /* ★ 必须把前端 session 也拉一遍:核层改的是它自己那份会话,前端这份 session.server
         还是旧线路 —— 而 poster/backdrop/thumb/person 的 URL 全是拿 session.server 现拼的。
         不刷的话,用户正因为旧线不通才切线路,切完图片却继续打那条死线,看起来「切了跟没切一样」。 */
      await refreshSession();
      say(`已切到${lineName(acct, index)}`);
    } catch (e) { fail("切换线路", e); }
  }

  /** 切版本:mpv 一次只开一路流,没有热换源 → 只能 stop 再 play。
      先 stop_playback 把进度落库(不然这一段观看记录直接丢),再用当前位置起播新 MediaSource。 */
  async function switchVersion(v: MediaVersion) {
    if (!playing || v.id === curMsId) return;
    const at = status.time;
    try {
      await stopPlayback(at);
      const resume = await play(playing.id, at, v.id);
      setCurMsId(v.id);
      setStatus((s) => ({ ...s, time: resume, paused: false }));
      // 新版本 = 新的音/字轨表,得重拉;沿用 afterStart 的 1.2s 等播放器就绪。
      // 但不走整个 afterStart:同一集重开,弹幕不该重置更不该再匹配一次。
      setTimeout(async () => {
        await applyPrefs().catch(() => {});
        setTracks(await tracksApi().catch(() => []));
      }, 1200);
      say(`已切换版本 · 从 ${fmtTime(resume)} 继续`);
    } catch (e) { fail("切换版本", e); }
  }

  // 标题溢出才跑马灯,短标题白晃眼(草稿标注 17)。
  useEffect(() => {
    const el = titleRef.current;
    if (!el) { setMarquee(false); return; }
    setMarquee(el.scrollWidth > el.clientWidth + 2);
  }, [playing]);

  const epIndex = playing ? siblings.findIndex((s) => s.id === playing.id) : -1;
  const prevEp = epIndex > 0 ? siblings[epIndex - 1] : null;
  const nextEp = epIndex >= 0 && epIndex < siblings.length - 1 ? siblings[epIndex + 1] : null;

  /** 切集:先把当前进度落库再起播,否则这一集的观看记录丢了。 */
  async function goEpisode(ep: Item | null, dir: "上" | "下") {
    if (ep) {
      await stopPlayback(status.time);
      await playItem(ep);
      return;
    }
    if (siblings.length === 0) say("当前条目没有剧集列表");
    else say(`已经是${dir === "上" ? "第一" : "最后一"}集了`);
  }

  /** 复制当前时间:纯前端,真能做。 */
  async function copyTime() {
    try {
      await navigator.clipboard.writeText(fmtTime(status.time));
      say(`已复制 ${fmtTime(status.time)}`);
    } catch {
      say("复制失败:剪贴板不可用");
    }
  }

  /* ---- 播放器可调项:先落 UI 再调核层,失败如实 toast ---- */

  /** 音量 0..100(mpv 收到 130 是软增益,竖条按草稿只给到 100)。拖动会高频触发,
      set_property 是内存写不打网络,不做节流。 */
  async function applyVolume(v: number) {
    const n = Math.round(Math.max(0, Math.min(100, v)));
    setVol(n);
    if (muted && n > 0) { setMuted(false); await setMuteApi(false).catch(() => {}); } // 拖音量=想听见
    try { await setVolumeApi(n); } catch (e) { fail("音量", e); }
  }
  async function applyMute(m: boolean) {
    setMuted(m);
    try { await setMuteApi(m); } catch (e) { setMuted(!m); fail("静音", e); }
  }
  /** 倍速:草稿范围 0.25×–5.0×(核层再 clamp 到 0.1–6)。 */
  async function applySpeed(v: number) {
    const s = Math.max(0.25, Math.min(5, round1(v * 100) / 100));
    speedRef.current = s; // 先记 ref:连调下一拍(120ms 后)靠它,等 state 回来就晚了
    setSpd(s);
    try { await setSpeedApi(s); } catch (e) { fail("倍速", e); }
  }
  /** 长按 +/− 连调(草稿 L1086):按下先走一步,之后每 120ms 一步,松手/移出即停。 */
  const stopRepeat = () => { if (repeat.current) { window.clearInterval(repeat.current); repeat.current = null; } };
  const holdRepeat = (step: () => void) => {
    step();
    stopRepeat(); // 防上一次 mouseup 丢了(比如在窗口外松的手)留下野 interval
    repeat.current = window.setInterval(step, 120);
  };
  const bumpSpeed = (d: number) => applySpeed(speedRef.current + d);
  // 组件卸载兜底:连调途中被卸载,interval 还在调一个不存在的播放器。
  useEffect(() => stopRepeat, []);
  async function applyADelay(v: number) {
    const s = round1(v);
    setADelay(s);
    try { await setAudioDelay(s); } catch (e) { fail("音频延迟", e); }
  }
  async function applySDelay(v: number) {
    const s = round1(v);
    setSDelay(s);
    try { await setSubDelay(s); } catch (e) { fail("字幕延迟", e); }
  }
  async function applyAspect(r: string) {
    setAspect(r); setArOpen(false);
    try { await setAspectRatioApi(r); say(`画面比例:${ASPECTS.find(([id]) => id === r)?.[1] ?? r}`); }
    catch (e) { fail("画面比例", e); }
  }
  async function applyHwdec(m: string) {
    setHw(m);
    if (m !== "no") setDolby(false); // 手动切回硬解 = 杜比软解自然失效,开关别再显示成开着
    try { await setHwdecApi(m); say(`解码方式:${HWDECS.find(([id]) => id === m)?.[1] ?? m}`); }
    catch (e) { fail("解码方式", e); }
  }
  /* 杜比视界软解 = gpu-next + 软解(本项目既定做法,见 [[dolby-auto-decode]])。
     核层 init 已无条件 set("vo","gpu-next")(mpv.rs:152),gpu-next 这半永远成立,
     故这里只切 hwdec:运行时改 vo 会触发 VO 重初始化(白闪/d3d11 上下文churn,
     本项目在这类坑上栽过),为设一个本就设好的值去冒这风险不值。 */
  async function applyDolby(on: boolean) {
    const mode = on ? "no" : "auto-safe";
    setDolby(on);
    setHw(mode);
    try {
      await setHwdecApi(mode);
      say(on ? "杜比视界软解已开启 · gpu-next + 软解" : "杜比视界软解已关闭 · 恢复硬解");
    } catch (e) { setDolby(!on); fail("杜比视界软解", e); }
  }
  /** 定时关闭:到点直接关播放器(closePlayer 会 stopPlayback 落进度,睡着了也不丢记录)。 */
  function applySleep(min: number | null) {
    if (sleepTimer.current) { window.clearTimeout(sleepTimer.current); sleepTimer.current = null; }
    setSleepMin(min);
    setSleepOpen(false);
    if (min == null) { say("已取消定时"); return; }
    sleepTimer.current = window.setTimeout(() => {
      sleepTimer.current = null;
      setSleepMin(null);
      closePlayer();
      say("已定时关闭播放");
    }, min * 60_000);
    say(`已设置 ${min} 分钟后关闭`);
  }
  /** 超分:核层挂完**双重回读** —— glsl-shaders 校验挂没挂上,尺寸校验会不会真跑。
      ★ 别只看 count 就报「已生效」:Anime4K 每个 pass 都带「输出 > 源 ×1.2」的门槛,
        窗口没比源大时整条链一帧都不跑,画面毫无变化,而旧文案还在说「已生效·挂载 6 个」——
        那就是假开,正是 [[superres-and-toast]] 要防的东西,结果自己又犯了一遍。 */
  async function applyShader(id: string) {
    try {
      const r = await setShaderLevel(id);
      setShaderLv(id);
      if (id === "off") { say("超分已关闭"); return; }
      // will_run=false:挂上了但不会跑 → 把核层给的真实数字原样告诉用户,别粉饰成成功。
      say(r.will_run === false && r.note ? r.note : `超分已生效 · 挂载 ${r.count} 个 shader`);
    } catch (e) {
      say(`超分未生效:${e}`); // 档位高亮不动:没生效就别显示成选中
    }
  }
  async function applySubStyle(o: { font?: string; size?: number; position?: number }) {
    if (o.font !== undefined) { setSubFont(o.font); setFontOpen(false); }
    if (o.size !== undefined) setSubSize(o.size);
    if (o.position !== undefined) setSubPos(o.position);
    try { await setSubStyle(o); } catch (e) { fail("字幕样式", e); }
  }
  async function applySec2(id: string) {
    setSec2(id);
    try { await setSecondarySub(id); } catch (e) { fail("次字幕", e); }
  }
  async function applySec2Opts(o: { delay?: number; position?: number }) {
    if (o.delay !== undefined) setSec2Delay(o.delay);
    if (o.position !== undefined) setSec2Pos(o.position);
    try { await setSecondarySubOpts(o); } catch (e) { fail("次字幕设置", e); }
  }
  /** 截图:核层返回落盘路径,报给用户(不然不知道存哪了)。 */
  async function doShot() {
    try { say(`截图已保存:${await screenshot()}`); } catch (e) { fail("截图", e); }
  }
  /** 外挂字幕:没装 @tauri-apps/plugin-dialog(且不为此加依赖),故用路径/URL 输入框。 */
  async function doAddSub() {
    const u = (subUrl || "").trim();
    if (!u) return;
    try {
      await addSubtitle(u);
      setSubUrl(null);
      // sub-add 用 flags=auto 不自动切轨,故刷新列表让用户自己选那条新字幕。
      setTracks(await tracksApi().catch(() => []));
      say("外挂字幕已加载,请在左侧列表选中");
    } catch (e) { fail("加载外挂字幕", e); }
  }

  /** 竖条贴着按钮弹(草稿 21):取按钮中心当锚点。 */
  const openVbar = (kind: "vol" | "bright", e: React.MouseEvent) => {
    if (vbar?.kind === kind) { setVbar(null); return; }
    const r = e.currentTarget.getBoundingClientRect();
    setVbar({ kind, x: r.left + r.width / 2 - 22 });
  };

  /** 竖条拖动:草稿要求「鼠标上下拖动」,故按下即跟随,松手结束。 */
  const dragVbar = (e: React.MouseEvent<HTMLElement>, set: (v: number) => void) => {
    const el = e.currentTarget;
    const apply = (clientY: number) => {
      const r = el.getBoundingClientRect();
      set(Math.round(Math.max(0, Math.min(100, ((r.bottom - clientY) / r.height) * 100))));
    };
    apply(e.clientY);
    const move = (ev: MouseEvent) => apply(ev.clientY);
    const up = () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  /* 键盘快捷键(草稿 kbdcard,取代移动端手势)。仅播放时生效,全部真调核层。 */
  useEffect(() => {
    if (!playing) return;
    const onKey = (e: KeyboardEvent) => {
      // 输入框里不劫持,否则弹幕搜索框敲不了字。
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;

      switch (e.key) {
        case " ": e.preventDefault(); togglePause(); break;
        case "ArrowLeft": e.preventDefault(); doSeek(status.time - 10); break;
        case "ArrowRight": e.preventDefault(); doSeek(status.time + 10); break;
        case "ArrowUp":
        case "ArrowDown": {
          e.preventDefault();
          applyVolume(volume + (e.key === "ArrowUp" ? 5 : -5));
          setVbar((b) => b?.kind === "vol" ? b : { kind: "vol", x: 24 }); // 顺手把竖条弹出来当读数
          break;
        }
        case "f": case "F": e.preventDefault(); toggleFullscreen(); break;
        case "Escape":
          e.preventDefault();
          if (ctx) setCtx(null);
          else if (vbar) setVbar(null);
          else if (panel) setPanel(null);
          else exitFullscreen();
          break;
        case "[": e.preventDefault(); applySpeed(speed - 0.25); say(`倍速 ${(Math.max(0.25, speed - 0.25)).toFixed(2)}×`); break;
        case "]": e.preventDefault(); applySpeed(speed + 0.25); say(`倍速 ${(Math.min(5, speed + 0.25)).toFixed(2)}×`); break;
        case "m": case "M": e.preventDefault(); applyMute(!muted); say(muted ? "已取消静音" : "已静音"); break;
        case "p": case "P": e.preventDefault(); goEpisode(prevEp, "上"); break;
        case "n": case "N": e.preventDefault(); goEpisode(nextEp, "下"); break;
        case "s": case "S": e.preventDefault(); doShot(); break;
        case "d": case "D": e.preventDefault(); setDmOn((v) => !v); break;
        default: break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [playing, status, panel, vbar, ctx, prevEp, nextEp, volume, muted, speed]);

  /* ★ danmaku_search 回的是 Vec<DanmakuSourceGroup>(一源一组),**不是**番剧数组:
     曾经这里按 {anime_id, anime_title, episodes} 收,渲染时 a.episodes.map() 直接
     TypeError 把整个播放器渲染打挂(白屏)。分组结构见 api.ts DanmakuSourceGroup,别再拍平。 */
  async function doDmSearch() {
    const q = dmKw.trim();
    if (!q) return;
    try { setDmResults(await danmakuSearch(q)); } catch (e) { fail("弹幕搜索", e); }
  }
  async function loadDmEpisode(ep: DanmakuEpisode) {
    try {
      setDmComments(await danmakuLoad(ep.episode_id));
      setDmOn(true);
      setDmResults(null);
      say(`弹幕已加载 · ${ep.episode_title || ep.episode_number || ""}`);
    } catch (e) { fail("加载弹幕", e); }
  }

  if (!booted) return null;
  if (!session) return <LoginPage onLoggedIn={setSession} />;

  const audio = tracks.filter((t) => t.kind === "audio");
  const subs = tracks.filter((t) => t.kind === "sub");
  const curTime = seeking ?? status.time;
  const pct = status.duration > 0 ? (curTime / status.duration) * 100 : 0;
  const bufPct = status.duration > 0 ? (status.buffered / status.duration) * 100 : 0;
  const wide = panel === "sub" || panel === "danmaku" || panel === "more";

  const pb = (i: React.ReactNode, label: string, on: boolean, click: (e: React.MouseEvent) => void, hot = false) => (
    <button className={`pb${on ? " on" : ""}${hot ? " hot" : ""}`} onClick={click} title={label}>
      <span className="i">{i}</span>
      {label}
    </button>
  );
  const togglePanel = (p: Panel) => () => { setPanel(panel === p ? null : p); setVbar(null); };
  /** 草稿的 stepper:−/＋ 夹一个值。 */
  const stepper = (label: string, val: React.ReactNode, dec: () => void, inc: () => void) => (
    <div className="p-li static" key={label}>
      {label}
      <span className="p-stepper">
        <button className="b" onClick={dec}>−</button>
        <b>{val}</b>
        <button className="b" onClick={inc}>＋</button>
      </span>
    </div>
  );
  /** 草稿的开关(尚无核层命令的项统一给诚实提示)。 */
  const swRow = (label: string, on: boolean, click: () => void) => (
    <div className="p-li static" key={label}>
      {label}
      <button className={`p-sw${on ? " on" : ""}`} onClick={click}><i /></button>
    </div>
  );

  // 标题:剧名 · S1E4 · 集名(草稿 L926)。
  const epTag = playing && playing.season_no != null && playing.episode_no != null
    ? `S${playing.season_no}E${playing.episode_no}` : null;
  const title = playing ? [playing.series_name, epTag, playing.name].filter(Boolean).join(" · ") : "";

  return (
    <>
      <div className={`app-root${playing ? " hidden" : ""}`}>
        <Shell
          session={session}
          onPlay={playItem}
          onPlaySource={playSource}
          onPlayDownload={playDownload}
          onSessionChange={refreshSession}
          searchOpen={searchOpen && !playing}
          onSearch={() => setSearchOpen(true)}
          onCloseSearch={() => setSearchOpen(false)}
        />
      </div>

      {/* 亮度遮罩:核层没有亮度命令,但 mpv 画面在网页层下面,盖一层黑就是真调光。
          放在 player-layer 外面,否则 OSD 淡出时亮度跟着一起变。 */}
      {playing && brightness < 100 && (
        <div className="p-dim" style={{ opacity: ((100 - brightness) / 100) * 0.85 }} />
      )}

      {/* 弹幕层外包一层:不透明度/显示区域纯 CSS 就能真生效(Danmaku.tsx 不动)。 */}
      {playing && (
        <div
          className="p-dmwrap"
          style={{ opacity: dmOpacity / 100, clipPath: `inset(0 0 ${100 - DM_AREAS[dmArea]}% 0)` }}
        >
          {/* 速度/字号:核层只管过滤去重,渲染参数本就是前端的事 → 直接透传 props。 */}
          <DanmakuLayer
            comments={dmComments}
            timeSync={timeSync}
            enabled={dmOn}
            duration={DM_SPEEDS[dmSpeed][0]}
            fontSize={DM_SIZES[dmSize][0] ?? undefined}
          />
        </div>
      )}

      {playing && (
        <div className={`player-layer${idle && !panel && !vbar && !ctx ? " idle" : ""}`}>
          {/* 画面区:接右键菜单(草稿 L1152),点空白收起弹出层 */}
          <div
            className="p-stage"
            onContextMenu={(e) => { e.preventDefault(); setCtx({ x: e.clientX, y: e.clientY }); }}
            onClick={() => { setVbar(null); setCtx(null); }}
          />

          {/* 顶栏 */}
          <div className="p-top">
            <button className="p-back" onClick={closePlayer} title="返回">
              <IconChevronLeft size={17} />
            </button>
            <span className={`p-title${marquee ? " run" : ""}`} ref={titleRef} title={title}>
              <b>{title}</b>
            </span>
            <span className="p-top-r">
              {pb("✦", "超分", panel === "super", togglePanel("super"))}
              {pb("⇄", "线路", panel === "line", togglePanel("line"))}
              {pb("◈", "版本", panel === "version", togglePanel("version"))}
              {pb("⋯", "更多", panel === "more", togglePanel("more"))}
              <span className="p-sep" />
              {pb(<IconFullscreen size={16} />, "全屏", false, toggleFullscreen, true)}
            </span>
          </div>

          {/* 底栏 */}
          <div className="p-bot">
            <div className="p-scrubrow">
              <span className="p-tc l">{fmtTime(curTime)}</span>
              {/* 悬停时间提示(草稿 pin 18)。缩略图那半要服务端 trickplay/BIF,核层确实没有
                  → 按草稿「没有就不显示、不硬凑」,只给时间读数,不画假缩略图。 */}
              <div
                className="p-scrub"
                onMouseMove={(e) => {
                  const r = e.currentTarget.getBoundingClientRect();
                  const x = Math.max(0, Math.min(r.width, e.clientX - r.left));
                  setHoverT({ x, t: (x / r.width) * status.duration });
                }}
                onMouseLeave={() => setHoverT(null)}
              >
                <span className="buf" style={{ width: `${bufPct}%` }} />
                <span className="fill" style={{ width: `${pct}%` }} />
                <span className="knob" style={{ left: `${pct}%` }} />
                {hoverT && status.duration > 0 && (
                  <span className="prev" style={{ left: hoverT.x }}><span className="tc">{fmtTime(hoverT.t)}</span></span>
                )}
                <input
                  type="range" min={0} max={Math.max(1, status.duration)} step={0.5}
                  value={curTime}
                  onChange={(e) => setSeeking(Number(e.target.value))}
                  onMouseUp={() => { if (seeking != null) { seekApi(seeking); setSeeking(null); } }}
                />
              </div>
              <span className="p-tc">{fmtTime(status.duration)}</span>
            </div>
            <div className="p-ctrls">
              <span className="p-grp">
                {pb(<IconPrev size={16} />, "上一集", false, () => goEpisode(prevEp, "上"))}
                {pb(<IconNext size={16} />, "下一集", false, () => goEpisode(nextEp, "下"))}
                <span className="p-sep" />
                {pb(<IconVolume size={16} />, "音量", vbar?.kind === "vol", (e) => openVbar("vol", e))}
                {pb(<IconSun size={16} />, "亮度", vbar?.kind === "bright", (e) => openVbar("bright", e))}
              </span>
              <span className="p-grp">
                {pb(<IconRewind size={16} />, "快退", false, () => doSeek(curTime - 10))}
                <button className="pb hot big" onClick={togglePause} title="播放/暂停">
                  <span className="i">{status.paused ? <IconPlay size={18} /> : <IconPause size={18} />}</span>
                  {status.paused ? "播放" : "暂停"}
                </button>
                {pb(<IconForward size={16} />, "快进", false, () => doSeek(curTime + 10))}
              </span>
              {/* 草稿底栏右恰好 5 键:选集·音轨·字幕·弹幕·倍速。
                  弹幕开关按草稿收在弹幕面板里(见 L1115),故这里点击=开面板,与另外 4 键一致;开关另有 D 键。 */}
              <span className="p-grp">
                {pb(<IconList size={16} />, "选集", panel === "eps", togglePanel("eps"))}
                {audio.length > 0 && pb("♪", "音轨", panel === "audio", togglePanel("audio"))}
                {pb("文", "字幕", panel === "sub", togglePanel("sub"))}
                {pb("弹", "弹幕", dmOn, togglePanel("danmaku"))}
                {pb("▸", "倍速", panel === "speed", togglePanel("speed"))}
              </span>
            </div>
          </div>

          {/* 音量 / 亮度竖条(草稿 21) */}
          {vbar && (
            <div className="p-vbar" style={{ left: vbar.x }}>
              {/* 音量条的图标兼作静音键(草稿没画独立静音键,M 键同此) */}
              {vbar.kind === "vol" ? (
                <button className={`ic mute${muted ? " on" : ""}`} onClick={() => applyMute(!muted)} title="静音 (M)">
                  <IconVolume size={14} />
                </button>
              ) : (
                <span className="ic"><IconSun size={14} /></span>
              )}
              <span
                className="track"
                onMouseDown={(e) => dragVbar(e, vbar.kind === "vol" ? applyVolume : setBrightness)}
              >
                <i style={{ height: `${vbar.kind === "vol" ? (muted ? 0 : volume) : brightness}%` }} />
                <span className="knob" style={{ bottom: `${vbar.kind === "vol" ? (muted ? 0 : volume) : brightness}%` }} />
              </span>
              <span className="v">{vbar.kind === "vol" ? (muted ? "静音" : volume) : brightness}</span>
            </div>
          )}

          {/* 右键画面菜单(草稿 L1152):截图/复制时间/硬解/比例 */}
          {ctx && (
            <>
              <div className="p-ctxmask" onClick={() => setCtx(null)} onContextMenu={(e) => { e.preventDefault(); setCtx(null); }} />
              <div className="ctxmenu" style={{ left: Math.min(ctx.x, window.innerWidth - 190), top: Math.min(ctx.y, window.innerHeight - 160) }}>
                <div className="mi" onClick={() => { setCtx(null); doShot(); }}><span className="i">◱</span>截图<span className="k">S</span></div>
                <div className="mi" onClick={() => { setCtx(null); copyTime(); }}><span className="i">⧉</span>复制当前时间</div>
                {/* 右键菜单是「常用项不翻面板」的快捷入口(草稿 L1152):就地切,不再开「更多」 */}
                <div className="mi" onClick={() => { setCtx(null); applyHwdec(hwdec === "no" ? "auto-safe" : "no"); }}>
                  <span className="i">⚙</span>{hwdec === "no" ? "切回硬解" : "切到软解"}
                </div>
                <div className="mi" onClick={() => { setCtx(null); setPanel("more"); setArOpen(true); }}>
                  <span className="i">▭</span>画面比例<span className="k">{ASPECTS.find(([id]) => id === aspect)?.[1]}</span>
                </div>
              </div>
            </>
          )}

          {/* 滑出面板的暗化背板:点空白 / Esc 收起(草稿 L998) */}
          {panel && <div className="p-scrim" onClick={() => setPanel(null)} />}

          {/* 右侧滑出面板 */}
          {panel && (
            <div className={`p-slide${wide ? " wide" : ""}`}>
              <div className="hd">
                {panelTitle(panel)}
                <button className="x" onClick={() => setPanel(null)}>✕</button>
              </div>
              <div className={`bd${wide ? " two" : ""}`}>
                {/* ---- 选集:item_detail(剧).children 是真数据(含 MediaSources 规格) ---- */}
                {panel === "eps" && (
                  siblings.length > 0 ? siblings.map((ep) => (
                    <button
                      key={ep.id}
                      className={`p-li${ep.id === playing.id ? " on" : ""}`}
                      onClick={() => { if (ep.id !== playing.id) goEpisode(ep, "下"); }}
                    >
                      <span className="thumb">
                        {ep.has_primary && <img src={posterUrl(session, ep.id, 120)} alt="" loading="lazy" />}
                      </span>
                      <span className="col">
                        <span className="t1">{ep.episode_no != null ? `E${ep.episode_no} ` : ""}{ep.name}</span>
                        <span className="t2">{[fmtRes(ep.video_height), fmtBitrate(ep.bitrate), fmtSize(ep.size_bytes)].filter(Boolean).join(" · ")}</span>
                      </span>
                      {ep.id === playing.id && <span className="rt">▶</span>}
                    </button>
                  )) : <div className="p-note">当前条目没有剧集列表(电影 / 网盘文件)。</div>
                )}

                {/* ---- 音轨:set_track + 音画同步(set_audio_delay)全真接 ---- */}
                {panel === "audio" && (
                  <>
                    {audio.map((t) => (
                      <button
                        key={t.id}
                        className={`p-li${t.selected ? " on" : ""}`}
                        onClick={() => { setTrack("audio", t.id); persistPrefs({ ...prefs, audio_lang: trackLang(audio, t.id) || prefs.audio_lang }); }}
                      >
                        <span className="rad" /> 音轨 {t.id} {t.lang || t.title}
                      </button>
                    ))}
                    <div className="grp-lab">音画同步</div>
                    {stepper("音频延迟", fmtDelay(aDelay), () => applyADelay(aDelay - 0.1), () => applyADelay(aDelay + 0.1))}
                    {aDelay !== 0 && (
                      <button className="p-li" onClick={() => applyADelay(0)}><span className="i"><IconRefresh size={13} /></span>归零</button>
                    )}
                    <div className="p-note">正值 = 音频延后播放(画面快于声音时用);步进 0.1s。</div>
                  </>
                )}

                {/* ---- 字幕:双栏。主字幕/样式/延迟/次字幕/外挂 全真接 ---- */}
                {panel === "sub" && (
                  <>
                    <div className="col">
                      <div className="grp-lab">主字幕</div>
                      <button className={`p-li${subs.every((t) => !t.selected) ? " on" : ""}`} onClick={() => { setTrack("sub", "no"); persistPrefs({ ...prefs, sub_enabled: false }); }}>
                        <span className="rad" /> 关闭
                      </button>
                      {subs.map((t) => (
                        <button
                          key={t.id}
                          className={`p-li${t.selected ? " on" : ""}`}
                          onClick={() => { setTrack("sub", t.id); persistPrefs({ ...prefs, sub_enabled: true, sub_lang: trackLang(subs, t.id) || prefs.sub_lang }); }}
                        >
                          <span className="rad" /> 字幕 {t.id} {t.lang || t.title}
                        </button>
                      ))}
                      {/* 没装 @tauri-apps/plugin-dialog,又不为此加依赖 → 退化成路径/URL 输入 */}
                      {subUrl === null ? (
                        <button className="p-li add" onClick={() => setSubUrl("")}>＋ 加载外挂字幕…</button>
                      ) : (
                        <>
                          <input
                            className="dmq" autoFocus placeholder="字幕本地路径 或 http(s):// URL"
                            value={subUrl}
                            onChange={(e) => setSubUrl(e.target.value)}
                            onKeyDown={(e) => { if (e.key === "Enter") doAddSub(); if (e.key === "Escape") setSubUrl(null); }}
                          />
                          <button className="p-li add" onClick={doAddSub}>确认加载</button>
                          <button className="p-li" onClick={() => setSubUrl(null)}>取消</button>
                        </>
                      )}
                      <div className="p-li static">
                        字体
                        <span className="rt sel" onClick={() => setFontOpen((o) => !o)}>
                          {SUB_FONTS.find(([id]) => id === subFont)?.[1] ?? subFont} ▾
                        </span>
                      </div>
                      {fontOpen && SUB_FONTS.map(([id, label]) => (
                        <button key={id} className={`p-li sub${subFont === id ? " on" : ""}`} onClick={() => applySubStyle({ font: id })}>
                          <span className="rad" /> {label}
                        </button>
                      ))}
                      {stepper("大小", `${subSize}`, () => applySubStyle({ size: Math.max(10, subSize - 5) }), () => applySubStyle({ size: Math.min(200, subSize + 5) }))}
                      {stepper("位置", `${subPos}`, () => applySubStyle({ position: Math.max(0, subPos - 5) }), () => applySubStyle({ position: Math.min(100, subPos + 5) }))}
                      {stepper("延迟", fmtDelay(sDelay), () => applySDelay(sDelay - 0.1), () => applySDelay(sDelay + 0.1))}
                    </div>
                    <div className="col">
                      <div className="grp-lab">次字幕(双字幕)</div>
                      <button className={`p-li${sec2 === "" ? " on" : ""}`} onClick={() => applySec2("")}>
                        <span className="rad" /> 关闭
                      </button>
                      {subs.map((t) => (
                        <button key={t.id} className={`p-li${sec2 === t.id ? " on" : ""}`} onClick={() => applySec2(t.id)}>
                          <span className="rad" /> 字幕 {t.id} {t.lang || t.title}
                        </button>
                      ))}
                      {stepper("位置 ", `${sec2Pos}`, () => applySec2Opts({ position: Math.max(0, sec2Pos - 5) }), () => applySec2Opts({ position: Math.min(100, sec2Pos + 5) }))}
                      {stepper("延迟 ", fmtDelay(sec2Delay), () => applySec2Opts({ delay: round1(sec2Delay - 0.1) }), () => applySec2Opts({ delay: round1(sec2Delay + 0.1) }))}
                      <div className="p-note">
                        次字幕只有位置/延迟可调:mpv 没有独立的次字幕字体/字号属性,样式跟随主字幕。
                      </div>
                    </div>
                    <div className="p-note span2">
                      位置 = mpv sub-pos:100 是底部(默认),数值越小字幕越靠上。延迟正值 = 字幕延后出现。
                    </div>
                  </>
                )}

                {/* ---- 弹幕:左=源(真接),右=显示设置(不透明度/区域纯 CSS 真生效) ---- */}
                {panel === "danmaku" && (
                  <>
                    <div className="col">
                      <div className="grp-lab">弹幕源 · 先搜索匹配</div>
                      <input className="dmq" placeholder="搜索片名 / 手动匹配…" value={dmKw} onChange={(e) => setDmKw(e.target.value)} onKeyDown={(e) => e.key === "Enter" && doDmSearch()} />
                      <button className="p-li" onClick={doDmSearch}><span className="rad" /> 搜索</button>
                      {/* 一源一组:g.animes → 每部番的 g.animes[].episodes 才是可点的集。
                          g.error 必须露出来 —— 单源挂了和单源没结果长得一样,吞了就没人知道该去修哪个源。 */}
                      {dmResults?.map((g) => (
                        <div key={g.source_id}>
                          <div className="grp-lab">{g.source_name}</div>
                          {g.error && <div className="p-note">该源失败:{g.error}</div>}
                          {!g.error && g.animes.length === 0 && <div className="p-note">该源没有结果</div>}
                          {g.animes.map((a) => (
                            <div key={`${g.source_id}:${a.anime_id}`}>
                              <div className="grp-lab">{a.anime_title}{a.year ? ` · ${a.year}` : ""}</div>
                              {a.episodes.map((ep) => (
                                <button key={ep.episode_id} className="p-li" onClick={() => loadDmEpisode(ep)}>
                                  <span className="thumb sq">
                                    {a.image_url && <img src={a.image_url} alt="" loading="lazy" />}
                                  </span>
                                  <span className="col">
                                    <span className="t1">{ep.episode_title || ep.episode_number || "?"}</span>
                                  </span>
                                  <span className="rt">{g.source_name}</span>
                                </button>
                              ))}
                            </div>
                          ))}
                        </div>
                      ))}
                      {dmResults && dmResults.length === 0 && <div className="p-note">没有可用的弹幕源(去设置页添加)。</div>}
                      {/* 弹幕源的增删改查在设置页(多源 CRUD);草稿 L1119 这里只要「搜索 / 选源」,
                          不再放 api_url 输入框 —— 它当年还把 Vec<DanmakuServer> 当单对象存,存了个寂寞。 */}
                      <div className="p-note">起播时会自动匹配弹幕;没匹配上或想换,在这儿搜片名手动挑。源的增删改在「设置 · 弹幕源」。</div>
                    </div>
                    <div className="col">
                      <div className="grp-lab">显示设置</div>
                      {swRow("弹幕开关", dmOn, () => setDmOn((v) => !v))}
                      {stepper("不透明度", `${dmOpacity}%`,
                        () => setDmOpacity((v) => Math.max(10, v - 10)),
                        () => setDmOpacity((v) => Math.min(100, v + 10)))}
                      {stepper("显示区域", DM_AREAS[dmArea] === 100 ? "全屏" : `${DM_AREAS[dmArea] / 25}/4 屏`,
                        () => setDmArea((i) => Math.max(0, i - 1)),
                        () => setDmArea((i) => Math.min(DM_AREAS.length - 1, i + 1)))}
                      {stepper("显示速度", DM_SPEEDS[dmSpeed][1],
                        () => setDmSpeed((i) => Math.max(0, i - 1)),
                        () => setDmSpeed((i) => Math.min(DM_SPEEDS.length - 1, i + 1)))}
                      {stepper("字体大小", DM_SIZES[dmSize][1],
                        () => setDmSize((i) => Math.max(0, i - 1)),
                        () => setDmSize((i) => Math.min(DM_SIZES.length - 1, i + 1)))}
                      <div className="p-note">
                        显示速度 = 滚动弹幕横穿屏幕的秒数(「中」=8s);字体大小「中」= 按画面高自适应。
                        这两项是前端渲染参数,核层 danmaku_filter 只管过滤/去重。
                      </div>
                    </div>
                  </>
                )}

                {/* ---- 版本:item_media 是真数据 ---- */}
                {panel === "version" && (
                  versions == null ? <div className="p-note">读取中…</div>
                    : versions.length === 0 ? <div className="p-note">没有取到版本信息。</div>
                      : <>
                        {versions.map((v) => {
                          const vid = v.streams.find((s) => s.type_ === "Video");
                          const spec = [fmtRes(vid?.height ?? null), vid?.video_range && vid.video_range !== "SDR" ? vid.video_range : null].filter(Boolean).join(" ");
                          return (
                            <button key={v.id} className={`p-li${v.id === curMsId ? " on" : ""}`} onClick={() => switchVersion(v)}>
                              <span className="rad" />
                              <span className="col">
                                <span className="t1">{spec || v.name}</span>
                                <span className="t2">{[v.container?.toUpperCase(), fmtBitrate(v.bitrate)].filter(Boolean).join(" · ")}</span>
                              </span>
                              <span className="rt">{fmtSize(v.size_bytes)}</span>
                            </button>
                          );
                        })}
                        <div className="p-note">列表为服务端真实版本(item_media)。点击即切换:先落进度再按当前位置用该版本重新起播(mpv 不支持热换源,必然有一次短暂重载)。</div>
                      </>
                )}

                {/* ---- 超分:档位来自核层 shader_levels(),挂载后回读校验 ---- */}
                {panel === "super" && (
                  shaderList.length === 0 ? <div className="p-note">读取档位中…</div> : (
                    <>
                      {shaderList.slice(0, 1).map(([id, name]) => (
                        <button key={id} className={`p-li${shaderLv === id ? " on" : ""}`} onClick={() => applyShader(id)}>
                          <span className="rad" /> {name}
                        </button>
                      ))}
                      <div className="grp-lab">Anime4K({shaderList.length - 1} 档)</div>
                      {shaderList.slice(1).map(([id, name]) => (
                        <button key={id} className={`p-li${shaderLv === id ? " on" : ""}`} onClick={() => applyShader(id)}>
                          <span className="rad" /> {name}
                        </button>
                      ))}
                      {/* 这段必须在点之前就说清楚:Anime4K 是**放大器**,不放大时它什么都不做,
                          而且它自己不会吭声 —— 用户只会看到「点了没反应」。 */}
                      <div className="p-note">
                        Anime4K 是放大器:只有画面区大于源画面 1.2 倍才工作。窗口播 1080p 通常不满足 —— 按 F 全屏。
                        档位越靠后越清晰也越吃显卡;挂载后回读 glsl-shaders 与画面尺寸双重校验,不会假装开了。
                      </div>
                    </>
                  )
                )}

                {/* ---- 线路:probe_lines / set_active_line 全真接 ---- */}
                {panel === "line" && (
                  lineErr ? <div className="p-note">线路探测失败:{lineErr}</div>
                    : !lineProbes || !acct ? <div className="p-note">探测中…</div>
                      : <>
                        {lineProbes.map((p) => (
                          <button
                            key={p.index}
                            className={`p-li${acct.active_line === p.index ? " on" : ""}`}
                            onClick={() => switchLine(p.index)}
                          >
                            <span className="rad" />
                            <span className="col">
                              <span className="t1">{lineName(acct, p.index)}</span>
                              <span className="t2">{p.url}</span>
                            </span>
                            {/* ms=null 是「探过、确实不通」,按草稿显示「—」,不装成 0ms */}
                            <span className="rt">{p.ms == null ? "—" : `${p.ms}ms`}</span>
                          </button>
                        ))}
                        <div className="grp-lab">进入服务器自动探测(GET /public,非 ping)· 缓存至退出程序清空 · 无需手动测速</div>
                      </>
                )}

                {/* ---- 倍速:set_speed 真接 ---- */}
                {panel === "speed" && (
                  <>
                    {/* 长按连调(草稿 L1086):mousedown 起跳并起 interval,松手/移出即停。
                        没有 onClick —— mousedown 已经走了第一步,再加 onClick 会一按走两格。 */}
                    <div className="p-li static center">
                      <span className="p-stepper">
                        <button
                          className="b"
                          onMouseDown={() => holdRepeat(() => bumpSpeed(-0.25))}
                          onMouseUp={stopRepeat} onMouseLeave={stopRepeat}
                        >−</button>
                        <b className="big">{speed.toFixed(2)}×</b>
                        <button
                          className="b"
                          onMouseDown={() => holdRepeat(() => bumpSpeed(0.25))}
                          onMouseUp={stopRepeat} onMouseLeave={stopRepeat}
                        >＋</button>
                      </span>
                    </div>
                    <div className="grp-lab">常用</div>
                    {SPEEDS.map((s) => (
                      <button key={s} className={`p-li${Math.abs(s - speed) < 0.01 ? " on" : ""}`} onClick={() => applySpeed(s)}>
                        <span className="rad" /> {s.toFixed(1)}×
                      </button>
                    ))}
                    <div className="grp-lab">范围 0.25×–5.0× · 步进 0.25 · 长按 +/− 连调 · 快捷键 [ / ]</div>
                  </>
                )}

                {/* ---- 更多:草稿十项。仅 跳过片头尾/PiP 尚无核层命令,余下全真接 ---- */}
                {panel === "more" && (
                  <>
                    <div className="p-li static">
                      解码方式
                      <span className="p-seg">
                        {HWDECS.map(([id, label]) => (
                          <button key={id} className={hwdec === id ? "on" : ""} onClick={() => applyHwdec(id)}>{label}</button>
                        ))}
                      </span>
                    </div>
                    <div className="p-li static">
                      画面比例
                      <span className="rt sel" onClick={() => setArOpen((o) => !o)}>
                        {ASPECTS.find(([id]) => id === aspect)?.[1] ?? aspect} ▾
                      </span>
                    </div>
                    {/* 「更多」的 bd 是双列网格,档位行直接铺会被拆到两列;裹一层 span2 才连成一张列表 */}
                    {arOpen && (
                      <div className="span2 col">
                        {ASPECTS.map(([id, label]) => (
                          <button key={id || "src"} className={`p-li sub${aspect === id ? " on" : ""}`} onClick={() => applyAspect(id)}>
                            <span className="rad" /> {label}
                          </button>
                        ))}
                      </div>
                    )}
                    {swRow("自动跳过片头", false, () => soon("自动跳过片头"))}
                    {swRow("自动跳过片尾", false, () => soon("自动跳过片尾"))}
                    {swRow("画中画 (PiP)", false, () => soon("画中画"))}
                    {/* 定时已开时整行点亮,不翻面板也看得出来 */}
                    <div className={`p-li static${sleepMin != null ? " on" : ""}`}>
                      定时播放
                      <span className="rt sel" onClick={() => setSleepOpen((o) => !o)}>
                        {sleepMin != null ? `${sleepMin} 分钟` : "关闭"} ▾
                      </span>
                    </div>
                    {sleepOpen && (
                      <div className="span2 col">
                        <button className={`p-li sub${sleepMin == null ? " on" : ""}`} onClick={() => applySleep(null)}>
                          <span className="rad" /> 关闭
                        </button>
                        {SLEEP_MINS.map((m) => (
                          <button key={m} className={`p-li sub${sleepMin === m ? " on" : ""}`} onClick={() => applySleep(m)}>
                            <span className="rad" /> {m} 分钟后关闭
                          </button>
                        ))}
                      </div>
                    )}
                    {swRow("杜比视界软解", dolby, () => applyDolby(!dolby))}
                    <button className="p-li" onClick={doShot}><span className="i">◱</span>截图 <span className="rt">S</span></button>
                    <button className="p-li" onClick={copyTime}><span className="i">⧉</span>复制当前时间</button>
                    <div className="p-note span2">
                      <b className="ttl"><IconInfo size={12} /> 播放信息 / 统计</b>
                      <span className="kv"><i>标题</i>{playing.name}</span>
                      {playing.series_name && <span className="kv"><i>剧集</i>{playing.series_name}{epTag ? ` · ${epTag}` : ""}</span>}
                      <span className="kv"><i>进度</i>{fmtTime(status.time)} / {fmtTime(status.duration)}</span>
                      <span className="kv"><i>已缓冲</i>{fmtTime(status.buffered)}</span>
                      <span className="kv"><i>状态</i>{status.paused ? "已暂停" : "播放中"}</span>
                      <span className="kv"><i>音/字轨</i>{audio.length} / {subs.length}</span>
                      {playing.video_height != null && <span className="kv"><i>规格</i>{[fmtRes(playing.video_height), fmtBitrate(playing.bitrate), fmtSize(playing.size_bytes)].filter(Boolean).join(" · ")}</span>}
                      {/* 以下几项是 player_opts 回读的真值,不是前端猜的 */}
                      <span className="kv"><i>倍速</i>{speed.toFixed(2)}×</span>
                      <span className="kv"><i>音量</i>{muted ? "静音" : volume}</span>
                      <span className="kv"><i>解码</i>{HWDECS.find(([id]) => id === hwdec)?.[1] ?? hwdec}</span>
                      <span className="kv"><i>超分</i>{shaderList.find(([id]) => id === shaderLv)?.[1] ?? shaderLv}</span>
                      {sleepMin != null && <span className="kv"><i>定时</i>{sleepMin} 分钟后关闭</span>}
                      <span className="kv note">跳过片头尾 / 画中画 核层尚无对应命令,待接。</span>
                    </div>
                  </>
                )}
              </div>
            </div>
          )}
        </div>
      )}

      {/* toast 放 player-layer 外:OSD 淡出时提示还得看得见 */}
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/** 线路显示名:用户起的名优先,没起名(或压根没配 lines,probe_lines 会回落单条)按草稿叫「主线 / 备线 N」。 */
function lineName(a: AccountInfo, i: number): string {
  return a.lines[i]?.name || (i === 0 ? "主线" : `备线 ${i}`);
}

function panelTitle(p: Panel): string {
  switch (p) {
    case "eps": return "选集";
    case "audio": return "音轨";
    case "sub": return "字幕";
    case "danmaku": return "弹幕";
    case "super": return "超分";
    case "line": return "线路";
    case "version": return "版本";
    case "speed": return "倍速";
    case "more": return "更多";
    default: return "";
  }
}
