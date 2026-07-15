import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  type Item,
  type LoginResult,
  type MediaVersion,
  type Prefs,
  type SourceEntry,
  type Status,
  type Track,
  addSubtitle,
  applyPrefs,
  currentSession,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  getPrefs,
  itemDetail,
  itemMedia,
  play,
  playerOpts,
  posterUrl,
  reportProgress,
  screenshot,
  seek as seekApi,
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

type DmEpisode = { episode_id: string; episode_title: string; episode_number: string | null };
type DmAnime = { anime_id: string; anime_title: string; episodes: DmEpisode[] };
type DmConfig = { api_url: string; auth_type: string; token: string };
type Panel = null | "eps" | "audio" | "sub" | "danmaku" | "super" | "line" | "version" | "speed" | "more";
/** 竖条弹出态:kind 决定调音量还是亮度,x 是按钮中心(贴着按钮弹,草稿 21)。 */
type VBar = null | { kind: "vol" | "bright"; x: number };

/** 草稿倍速面板「常用」档位。 */
const SPEEDS = [0.5, 1.0, 1.5, 2.0, 3.0];
/** 弹幕显示区域档位 → 占屏高百分比(草稿 stepper「1/2 屏」)。 */
const DM_AREAS = [25, 50, 75, 100];
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
  const [vbar, setVbar] = useState<VBar>(null);
  const [volume, setVol] = useState(70); // 真接 set_volume;起播后由 player_opts 覆盖成真值
  const [muted, setMuted] = useState(false);
  const [brightness, setBrightness] = useState(100); // 纯前端黑遮罩,真生效

  // 播放器可调项:初值都是占位,起播后 player_opts() 拉真值覆盖(否则滑块位置是假的)
  const [speed, setSpd] = useState(1);
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

  // 弹幕
  const [dmComments, setDmComments] = useState<DanmakuComment[]>([]);
  const [dmOn, setDmOn] = useState(false);
  const [dmResults, setDmResults] = useState<DmAnime[] | null>(null);
  const [dmKw, setDmKw] = useState("");
  const [dmCfg, setDmCfg] = useState<DmConfig>({ api_url: "", auth_type: "none", token: "" });
  const [dmOpacity, setDmOpacity] = useState(80); // 纯 CSS,真生效
  const [dmArea, setDmArea] = useState(1); // DM_AREAS 下标,纯 CSS 裁剪,真生效
  const timeSync = useRef<TimeSync>({ base: 0, stamp: performance.now(), paused: false });

  useEffect(() => {
    (async () => {
      const s = await currentSession().catch(() => null);
      if (s) setSession(s);
      getPrefs().then(setPrefs2).catch(() => {});
      invoke<DmConfig>("get_danmaku_config").then(setDmCfg).catch(() => {});
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

  /** OSD 统一提示(复用 ui.css 的 .toast)。 */
  function say(msg: string) {
    setToast(msg);
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 2400);
  }
  /** 核层确实没有的命令:诚实告知,不装作能用。 */
  const soon = (what: string) => say(`${what}:核层暂无对应命令,待接`);
  /** 真调用失败一律如实说,不静默吞(尤其超分:吞掉就成了「以为开了其实没开」)。 */
  const fail = (what: string, e: unknown) => say(`${what}失败:${e}`);

  async function afterStart(name: string) {
    setDmComments([]);
    setDmOn(false);
    setDmKw(name);
    setPanel(null);
    setVersions(null);
    // 换片重置前端侧样式态(核层是新播放器实例,旧的延迟/次字幕都没了)。
    setSubUrl(null);
    setADelay(0); setSDelay(0);
    setSec2(""); setSec2Delay(0); setSec2Pos(100);
    setSubSize(55); setSubPos(100); setSubFont("sans-serif");
    setAspect(""); setShaderLv("off");
    setSleepMin(null); setSleepOpen(false); setDolby(false); // 定时句柄由 [playing] 的 cleanup 清
    setTimeout(async () => {
      await applyPrefs().catch(() => {});
      setTracks(await tracksApi().catch(() => []));
      // 音量/倍速/静音/延迟/解码拉真值 —— 否则 OSD 滑块显示的是前端瞎猜的初值。
      try {
        const o = await playerOpts();
        setVol(Math.round(o.volume));
        setMuted(o.muted);
        setSpd(o.speed);
        setADelay(round1(o.audio_delay));
        setSDelay(round1(o.sub_delay));
        setHw(normHwdec(o.hwdec));
        setShaderLv((lv) => (o.shader_count > 0 ? lv : "off"));
      } catch { /* 播放器未就绪:保持占位值,不弹错打扰起播 */ }
    }, 1200);
  }

  async function playItem(it: Item) {
    try {
      const resume = await play(it.id, it.resume_secs);
      setPlaying(it);
      setStatus({ time: resume, duration: it.runtime_secs, paused: false, buffered: 0 });
      afterStart(it.name);
    } catch (e) {
      alert(String(e));
    }
  }

  async function playSource(entry: SourceEntry) {
    try {
      const start = await sourcePlay(entry, 0);
      // 网盘文件不是 Emby 条目:剧集号/规格字段一律 null。
      const synth: Item = { id: entry.id, name: entry.name, type_: "Video", is_folder: false, has_primary: false, runtime_secs: 0, resume_secs: 0, series_name: null, episode_no: null, season_no: null, video_height: null, bitrate: null, size_bytes: null };
      setPlaying(synth);
      setStatus({ time: start, duration: 0, paused: false, buffered: 0 });
      afterStart(entry.name);
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
    itemMedia(playing.id).then(setVersions).catch(() => setVersions([]));
  }, [panel, playing, versions]);

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
    setSpd(s);
    try { await setSpeedApi(s); } catch (e) { fail("倍速", e); }
  }
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
  /** 超分:核层挂完回读 glsl-shaders 校验,非 off 却 0 会 reject —— 必须如实报,
      不能吞(见 [[superres-and-toast]]:软件纹理根本不跑 glsl,吞了就是假开)。 */
  async function applyShader(id: string) {
    try {
      const n = await setShaderLevel(id);
      setShaderLv(id);
      say(id === "off" ? "超分已关闭" : `超分已生效 · 挂载 ${n} 个 shader`);
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

  async function doDmSearch() {
    const q = dmKw.trim();
    if (!q) return;
    try { setDmResults(await invoke<DmAnime[]>("danmaku_search", { keyword: q })); } catch (e) { alert(String(e)); }
  }
  async function loadDmEpisode(ep: DmEpisode) {
    try {
      const cs = await invoke<DanmakuComment[]>("danmaku_load", { episodeId: ep.episode_id });
      setDmComments(cs); setDmOn(true); setDmResults(null);
    } catch (e) { alert(String(e)); }
  }
  const saveDmCfg = () => invoke("set_danmaku_config", { apiUrl: dmCfg.api_url, authType: dmCfg.auth_type, token: dmCfg.token }).catch(() => {});

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
          connected
          onPlay={playItem}
          onPlaySource={playSource}
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
          <DanmakuLayer comments={dmComments} timeSync={timeSync} enabled={dmOn} />
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
              <div className="p-scrub">
                <span className="buf" style={{ width: `${bufPct}%` }} />
                <span className="fill" style={{ width: `${pct}%` }} />
                <span className="knob" style={{ left: `${pct}%` }} />
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
                      {dmResults?.map((a) => (
                        <div key={a.anime_id}>
                          <div className="grp-lab">{a.anime_title}</div>
                          {a.episodes.map((ep) => (
                            <button key={ep.episode_id} className="p-li" onClick={() => loadDmEpisode(ep)}>
                              <span className="rad" /> {ep.episode_title || ep.episode_number || "?"}
                            </button>
                          ))}
                        </div>
                      ))}
                      {dmResults && dmResults.length === 0 && <div className="p-note">没有找到弹幕</div>}
                      <div className="grp-lab">弹幕源设置</div>
                      <input className="dmq" placeholder="弹幕服务器 http://host" value={dmCfg.api_url} onChange={(e) => setDmCfg({ ...dmCfg, api_url: e.target.value })} />
                      <button className="p-li" onClick={saveDmCfg}><span className="rad" /> 保存源</button>
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
                      {stepper("显示速度", "中", () => soon("弹幕速度"), () => soon("弹幕速度"))}
                      {stepper("字体大小", "中", () => soon("弹幕字号"), () => soon("弹幕字号"))}
                      <div className="p-note">速度/字号在 Danmaku 画布内部固定,需该组件开放 props,待接。</div>
                    </div>
                  </>
                )}

                {/* ---- 版本:item_media 是真数据 ---- */}
                {panel === "version" && (
                  versions == null ? <div className="p-note">读取中…</div>
                    : versions.length === 0 ? <div className="p-note">没有取到版本信息。</div>
                      : <>
                        {versions.map((v, i) => {
                          const vid = v.streams.find((s) => s.type_ === "Video");
                          const spec = [fmtRes(vid?.height ?? null), vid?.video_range && vid.video_range !== "SDR" ? vid.video_range : null].filter(Boolean).join(" ");
                          return (
                            <button key={v.id} className={`p-li${i === 0 ? " on" : ""}`} onClick={() => say("切换版本需重新起播,核层暂无该命令")}>
                              <span className="rad" />
                              <span className="col">
                                <span className="t1">{spec || v.name}</span>
                                <span className="t2">{[v.container?.toUpperCase(), fmtBitrate(v.bitrate)].filter(Boolean).join(" · ")}</span>
                              </span>
                              <span className="rt">{fmtSize(v.size_bytes)}</span>
                            </button>
                          );
                        })}
                        <div className="p-note">列表为服务端真实版本;切换版本需重新起播(核层 play 只认 item_id),待接。</div>
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
                      <div className="p-note">后续接入更多超分模型(不止 Anime4K)· 仅 mpv/原生 MPV。挂载后回读 glsl-shaders 校验:没真生效会报错,不会假装开了。</div>
                    </>
                  )
                )}

                {/* ---- 线路:核层无探测命令 ---- */}
                {panel === "line" && (
                  <>
                    <button className="p-li on" onClick={() => soon("线路")}><span className="rad" /> 主线 <span className="rt">—</span></button>
                    <div className="grp-lab">进入服务器自动探测(GET /public,非 ping)· 缓存至退出程序清空 · 无需手动测速</div>
                    <div className="p-note">多线路探测需核层命令,待接。</div>
                  </>
                )}

                {/* ---- 倍速:set_speed 真接 ---- */}
                {panel === "speed" && (
                  <>
                    <div className="p-li static center">
                      <span className="p-stepper">
                        <button className="b" onClick={() => applySpeed(speed - 0.25)}>−</button>
                        <b className="big">{speed.toFixed(2)}×</b>
                        <button className="b" onClick={() => applySpeed(speed + 0.25)}>＋</button>
                      </span>
                    </div>
                    <div className="grp-lab">常用</div>
                    {SPEEDS.map((s) => (
                      <button key={s} className={`p-li${Math.abs(s - speed) < 0.01 ? " on" : ""}`} onClick={() => applySpeed(s)}>
                        <span className="rad" /> {s.toFixed(1)}×
                      </button>
                    ))}
                    <div className="grp-lab">范围 0.25×–5.0× · 步进 0.25 · 快捷键 [ / ]</div>
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
