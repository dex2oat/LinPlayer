import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { listen } from "@tauri-apps/api/event";
import QRCode from "qrcode";
import "./SettingsPage.css";
import {
  type AccountInfo,
  type CfProxyStatus,
  type CfTestResult,
  type DanmakuServer,
  type PrefetchSettings,
  type ProxyConfig,
  type SyncAccount,
  type TraktDeviceCode,
  type WritebackSettings,
  getPrefs,
  setPrefs,
  getProxy,
  setProxy,
  getDanmakuConfig,
  setDanmakuConfig,
  traktAccount,
  traktDeviceCode,
  traktPoll,
  traktLogout,
  bangumiAccount,
  bangumiAuthorizeUrl,
  bangumiExchange,
  bangumiLogout,
  configExportQr,
  configImportQr,
  fmtSize,
  getTranslationSettings,
  setTranslationSettings,
  translationEngineStatus,
  whisperModels,
  whisperDownload,
  whisperDelete,
  whisperDeps,
  whisperDownloadFfmpeg,
  listAccounts,
  cfSpeedTest,
  cfProxyEnable,
  cfProxyDisable,
  cfProxyStatus,
  getPrefetchSettings,
  setPrefetchSettings,
  getCrossServerResume,
  setCrossServerResume,
  getWritebackSettings,
  setWritebackSettings,
  pluginList,
  pluginEnable,
  pluginDisable,
  pluginInstall,
  pluginUninstall,
} from "../lib/api";
import {
  IconSun,
  IconPlay,
  IconLibrary,
  IconFile,
  IconCloud,
  IconServer,
  IconRefresh,
  IconHeart,
  IconInfo,
  IconSettings,
  IconSearch,
} from "../app/icons";

/* ============================================================
   设置页 —— 严格照 docs/desktop-drafts.html PAGE 7:
   cbar(面包屑 + 搜索设置项) → .md 主从两栏:
   左 .mdnav(.sec/.it) 右 .mdpane(h4/.hint + .setrow/.sw/.seg/.stepper/.field)。
   改完即生效(输入 blur / 开关点按即调命令),绿字/toast 反馈。
   没接的一律诚实标注,不造假。
   ============================================================ */

type Theme = "dark" | "light";
type Props = { theme: Theme; setTheme: (t: Theme) => void; onOpenCalendar: () => void };

/* ---------- 即时反馈 ---------- */
type Msg = { kind: "ok" | "err"; text: string };
function Flash({ msg }: { msg: Msg | null }) {
  const [show, setShow] = useState<Msg | null>(msg);
  useEffect(() => {
    setShow(msg);
    if (!msg) return;
    const t = setTimeout(() => setShow(null), msg.kind === "err" ? 5000 : 2400);
    return () => clearTimeout(t);
  }, [msg]);
  if (!show) return null;
  return show.kind === "err" ? (
    <div className="toast error">{show.text}</div>
  ) : (
    <span className="st-ok">{show.text}</span>
  );
}
function useFlash() {
  const [msg, setMsg] = useState<Msg | null>(null);
  return {
    ok: (text: string) => setMsg({ kind: "ok", text }),
    err: (e: unknown) => setMsg({ kind: "err", text: String(e) }),
    node: <Flash msg={msg} />,
  };
}

const copy = (t: string) => navigator.clipboard?.writeText(t);

/** 取 host 当回落显示名(源没起名时)。URL 还没填完就返空,别抛。 */
function hostOf(u: string): string {
  try {
    return new URL(u).host;
  } catch {
    return "";
  }
}

/* ---------- 草稿控件(全局类) ---------- */
function Sw({
  on,
  onChange,
  disabled,
}: {
  on: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className={"sw" + (on ? " on" : "")}
      role="switch"
      aria-checked={on}
      disabled={disabled}
      style={disabled ? { opacity: 0.45 } : undefined}
      onClick={() => onChange(!on)}
    >
      <i />
    </button>
  );
}

function Seg<T extends string>({
  value,
  opts,
  onChange,
}: {
  value: T;
  opts: { id: T; label: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <span className="seg">
      {opts.map((o) => (
        <span
          key={o.id}
          className={value === o.id ? "on" : ""}
          onClick={() => onChange(o.id)}
        >
          {o.label}
        </span>
      ))}
    </span>
  );
}

function Stepper({
  value,
  onChange,
  min,
  max,
  step,
  fmt,
}: {
  value: number;
  onChange: (v: number) => void;
  min: number;
  max: number;
  step: number;
  fmt: (v: number) => string;
}) {
  const round = (v: number) => Math.round(v / step) * step;
  return (
    <span className="stepper">
      <button
        type="button"
        className="b"
        onClick={() => onChange(Math.max(min, +round(value - step).toFixed(2)))}
      >
        −
      </button>
      <span className="v">{fmt(value)}</span>
      <button
        type="button"
        className="b"
        onClick={() => onChange(Math.min(max, +round(value + step).toFixed(2)))}
      >
        ＋
      </button>
    </span>
  );
}

/* setrow 快捷:左标题(+说明) + 右控件 */
function Row({
  t,
  d,
  children,
}: {
  t: string;
  d?: string;
  children: ReactNode;
}) {
  return (
    <div className="setrow">
      <span className="l">
        <span className="t">{t}</span>
        {d && <span className="d">{d}</span>}
      </span>
      <span className="ctl">{children}</span>
    </div>
  );
}

/* ============================================================
   通用 · 外观与语言
   ============================================================ */
function AppearancePane({ theme, setTheme }: { theme: Theme; setTheme: (t: Theme) => void }) {
  return (
    <div className="mdpane">
      <h4>外观与语言</h4>
      <p className="hint">主题与界面语言,切换立即生效并记住。</p>
      <Row t="界面主题" d="深色影院 / 米黄护眼,二选一">
        <Seg<Theme>
          value={theme}
          opts={[
            { id: "dark", label: "深色" },
            { id: "light", label: "米黄浅色" },
          ]}
          onChange={setTheme}
        />
      </Row>
      <Row t="界面语言" d="目前仅简体中文,多语言待接">
        <span className="muted">简体中文</span>
      </Row>
    </div>
  );
}

/* ============================================================
   通用 · 播放器
   audio_lang / sub_lang / sub_enabled 真落 prefs(set_prefs);
   记忆播放进度 · 跨服续播 真落 prefs.cross_server_resume
     (get/set_cross_server_resume —— 核层默认**关**,别在前端硬编码 true 假装开着)。

   其余仍是本机暂存,且是**已核实**的真缺口 —— core config.rs 的 Prefs 只有
   audio_lang、sub_lang、sub_enabled、cross_server_resume、cross_server_writeback 三项、
   prefetch 三项;
   下面这几项核层压根没有落点(默认解码方式:set_hwdec 只作用于运行中的 mpv 实例,
   不持久化;跳过片头片尾/缩略图/默认倍速/杜比软解/外部 MPV:无字段无命令)。
   —— 有落点的别跟着一起被抹黑,没落点的别假装已接。
   ============================================================ */
const LP_KEY = "lp.playback.local";
type LocalPlayback = {
  decode: "hw" | "sw";
  skip: boolean;
  thumbs: boolean;
  speed: number;
  dolby: boolean;
  external: string;
};
const LP_DEFAULT: LocalPlayback = {
  decode: "hw",
  skip: false,
  thumbs: true,
  speed: 1,
  dolby: true,
  external: "",
};
function loadLocal(): LocalPlayback {
  try {
    return { ...LP_DEFAULT, ...JSON.parse(localStorage.getItem(LP_KEY) || "{}") };
  } catch {
    return LP_DEFAULT;
  }
}

function PlaybackPane() {
  const f = useFlash();
  const [audio, setAudio] = useState("");
  const [sub, setSub] = useState("");
  const [subOn, setSubOn] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [lp, setLp] = useState<LocalPlayback>(loadLocal);
  /* null = 还没读回来。核层默认关,所以初值不能写 true —— 写死 true 会在读回前
     把「关」画成「开」,用户以为开着其实没开。 */
  const [resume, setResume] = useState<boolean | null>(null);

  useEffect(() => {
    let alive = true;
    getPrefs()
      .then((p) => {
        if (!alive) return;
        setAudio(p.audio_lang ?? "");
        setSub(p.sub_lang ?? "");
        setSubOn(p.sub_enabled);
        setLoaded(true);
      })
      .catch(f.err);
    getCrossServerResume()
      .then((v) => alive && setResume(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /* 跨服续播:点即调命令。失败要回滚 UI —— 否则开关停在「开」而磁盘是「关」。 */
  async function toggleResume(v: boolean) {
    const prev = resume;
    setResume(v);
    try {
      await setCrossServerResume(v);
      f.ok("已保存");
    } catch (e) {
      setResume(prev);
      f.err(e);
    }
  }

  // 本机偏好:改完即存(localStorage),播放核接入后消费。
  function patchLocal(p: Partial<LocalPlayback>) {
    setLp((prev) => {
      const next = { ...prev, ...p };
      localStorage.setItem(LP_KEY, JSON.stringify(next));
      return next;
    });
  }

  // 真 prefs:改完即调命令(输入 blur / 开关点按)。
  async function savePrefs(next?: { audio?: string; sub?: string; subOn?: boolean }) {
    try {
      await setPrefs({
        audio_lang: (next?.audio ?? audio).trim() || null,
        sub_lang: (next?.sub ?? sub).trim() || null,
        sub_enabled: next?.subOn ?? subOn,
      });
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>播放器</h4>
      <p className="hint">解码、进度、字幕默认行为。</p>

      <Row t="默认解码方式" d="硬解省电、软解兼容">
        <Seg<"hw" | "sw">
          value={lp.decode}
          opts={[
            { id: "hw", label: "硬解" },
            { id: "sw", label: "软解" },
          ]}
          onChange={(decode) => patchLocal({ decode })}
        />
      </Row>
      <Row t="记忆播放进度 · 跨服续播" d="同一部片在多台服务器上取最大进度续播">
        <Sw on={resume ?? false} disabled={resume === null} onChange={toggleResume} />
      </Row>
      <Row t="自动跳过片头 / 片尾">
        <Sw on={lp.skip} onChange={(skip) => patchLocal({ skip })} />
      </Row>
      <Row t="进度条缩略图预览" d="需服务端提供 trickplay,缺失则不显示">
        <Sw on={lp.thumbs} onChange={(thumbs) => patchLocal({ thumbs })} />
      </Row>
      <Row t="默认倍速">
        <Stepper
          value={lp.speed}
          min={0.25}
          max={3}
          step={0.25}
          fmt={(v) => `${v.toFixed(2)}×`}
          onChange={(speed) => patchLocal({ speed })}
        />
      </Row>
      <Row t="杜比视界自动软解">
        <Sw on={lp.dolby} onChange={(dolby) => patchLocal({ dolby })} />
      </Row>

      <div className="fld" style={{ marginTop: 14 }}>
        <label>外部播放器(外部 MPV 路径)</label>
        <input
          className="field"
          placeholder="未设置 —— 留空用内置播放器"
          value={lp.external}
          onChange={(e) => patchLocal({ external: e.target.value })}
        />
      </div>
      <p className="hint" style={{ margin: "2px 0 18px" }}>
        其中<b>默认解码方式 / 自动跳过片头片尾 / 进度条缩略图 / 默认倍速 / 杜比视界自动软解 /
        外部播放器</b>这 6 项核心尚无落点,仅存本机、<b>尚未影响实际播放</b>;
        「记忆播放进度 · 跨服续播」与下方轨道语言偏好已真落核心配置,改完即生效。
      </p>

      <h4 style={{ marginTop: 6 }}>轨道语言偏好</h4>
      <p className="hint">按语言优先选音轨与字幕(ISO 三字母,留空=自动)。改完离开输入框即保存。</p>
      <div className="fld">
        <label>首选音频语言</label>
        <input
          className="field"
          placeholder="如 chi / jpn / eng"
          value={audio}
          disabled={!loaded}
          onChange={(e) => setAudio(e.target.value)}
          onBlur={() => savePrefs()}
        />
      </div>
      <div className="fld">
        <label>首选字幕语言</label>
        <input
          className="field"
          placeholder="如 chi / jpn / eng"
          value={sub}
          disabled={!loaded}
          onChange={(e) => setSub(e.target.value)}
          onBlur={() => savePrefs()}
        />
      </div>
      <Row t="默认加载字幕" d="关闭则播放时不自动挂字幕轨">
        <Sw
          on={subOn}
          onChange={(v) => {
            setSubOn(v);
            savePrefs({ subOn: v });
          }}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   通用 · 弹幕
   ============================================================ */
const DANMAKU_AUTH = [
  { id: "none", label: "无鉴权" },
  { id: "pathToken", label: "路径 Token" },
  { id: "headerToken", label: "请求头 Token" },
  { id: "queryToken", label: "查询参数 Token" },
];
/* 核层存的一直是**一张源表**(Vec<DanmakuServer>),并行拉取后按 priority 挑主源。
   之前这里只编辑单个源 —— 读回来的数组塞进对象、写出去少个参数,两头都静默失败。 */
function DanmakuPane() {
  const f = useFlash();
  const [list, setList] = useState<DanmakuServer[] | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    getDanmakuConfig()
      .then((l) => alive && setList(l))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /** 存盘即读回:核层会补 id、排序,不读回来前端就和磁盘不一致了。 */
  async function commit(next: DanmakuServer[]) {
    setList(next);
    if (busy) return;
    setBusy(true);
    try {
      await setDanmakuConfig(next);
      setList(await getDanmakuConfig());
      f.ok("弹幕源已保存");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  const patch = (i: number, o: Partial<DanmakuServer>) =>
    setList((l) => (l ? l.map((s, j) => (j === i ? { ...s, ...o } : s)) : l));

  /* f.node 挂在加载分支里:getDanmakuConfig 失败时 list 恒为 null,不挂就没地方出错误。 */
  if (!list)
    return (
      <div className="mdpane">
        <h4>弹幕</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );

  return (
    <div className="mdpane">
      <h4>弹幕</h4>
      <p className="hint">
        弹弹play 兼容的弹幕源,可配多个:并行拉取,按优先级(越小越先)挑主源;
        单源失败不影响其它源。
      </p>

      {list.length === 0 && <p className="hint">还没有弹幕源,点下方「添加源」。</p>}

      {list.map((s, i) => (
        <div className="st-card" key={s.id || i}>
          <div className="setrow">
            <span className="l">
              <span className="t">{s.name?.trim() || hostOf(s.api_url) || `源 ${i + 1}`}</span>
              <span className="d">{s.enabled ? "已启用" : "已停用"}</span>
            </span>
            <span className="ctl" style={{ display: "flex", gap: 10, alignItems: "center" }}>
              <Sw on={s.enabled} onChange={(v) => commit(list.map((x, j) => (j === i ? { ...x, enabled: v } : x)))} />
              <button className="btn" onClick={() => commit(list.filter((_, j) => j !== i))}>
                删除
              </button>
            </span>
          </div>
          <div className="fld">
            <label>名称(可选)</label>
            <input
              className="field"
              placeholder="留空则用域名"
              value={s.name}
              onChange={(e) => patch(i, { name: e.target.value })}
              onBlur={() => commit(list)}
            />
          </div>
          <div className="fld">
            <label>API 地址</label>
            <input
              className="field"
              placeholder="https://api.dandanplay.net"
              value={s.api_url}
              onChange={(e) => patch(i, { api_url: e.target.value })}
              onBlur={() => commit(list)}
            />
          </div>
          <div className="fld">
            <label>鉴权方式</label>
            <select
              className="field"
              style={{ cursor: "pointer" }}
              value={s.auth_type || "none"}
              onChange={(e) => commit(list.map((x, j) => (j === i ? { ...x, auth_type: e.target.value } : x)))}
            >
              {DANMAKU_AUTH.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.label}
                </option>
              ))}
            </select>
          </div>
          {s.auth_type !== "none" && (
            <div className="fld">
              <label>Token</label>
              <input
                className="field"
                placeholder="鉴权令牌"
                value={s.token}
                onChange={(e) => patch(i, { token: e.target.value })}
                onBlur={() => commit(list)}
              />
            </div>
          )}
          <div className="setrow">
            <span className="l">
              <span className="t">优先级</span>
              <span className="d">越小越先用</span>
            </span>
            <span className="ctl">
              <Stepper
                value={s.priority}
                min={0}
                max={99}
                step={1}
                fmt={(v) => String(v)}
                onChange={(v) => commit(list.map((x, j) => (j === i ? { ...x, priority: v } : x)))}
              />
            </span>
          </div>
        </div>
      ))}

      <div className="st-actions">
        <button
          className="btn primary"
          disabled={busy}
          onClick={() =>
            commit([
              ...list,
              { id: "", name: "", api_url: "", auth_type: "none", token: "", enabled: true, priority: list.length },
            ])
          }
        >
          ＋ 添加源
        </button>
        {f.node}
      </div>
    </div>
  );
}

/* ============================================================
   通用 · 字幕翻译
   ★ 线上格式坑:core 的 TranslationSettings 打了 #[serde(rename_all="camelCase")],
     **Rust 字段名 ≠ 线上键名** —— target_lang 上线是 targetLang、baidu_general 是
     baiduGeneral、whisper_enabled 是 whisperEnabled。照 Rust 字段名写 snake_case 会被
     serde 当未知字段丢掉,而所有字段都带 #[serde(default)] → 反序列化**不报错**,
     直接给你一份默认值存回磁盘,把用户填的 key 全抹了。别改成 snake_case。
     引擎/排版/模型的枚举值同理走 camelCase / lowercase:
     openai|anthropic|baiduGeneral|baiduLlm|tencent、
     translatedOnly|translatedFirst|originalFirst、tiny|base|medium|large。
   ============================================================ */
type AiCfg = { baseUrl: string; apiKey: string; model: string };
type BaiduCfg = { endpoint: string; appId: string; secretKey: string; apiKey: string };
type TencentCfg = { secretId: string; secretKey: string; region: string; projectId: number };
type TrSettings = {
  engine: string;
  targetLang: string;
  layout: string;
  openai: AiCfg;
  anthropic: AiCfg;
  baiduGeneral: BaiduCfg;
  baiduLlm: BaiduCfg;
  tencent: TencentCfg;
  whisperEnabled: boolean;
  whisperModel: string;
  whisperMirror: string;
  whisperBinary: string;
  ffmpegPath: string;
};
/* core WhisperModelInfo 实际返回 key/display_name/size_label/downloaded/downloaded_bytes。
   api.ts 的 WhisperModelInfo 类型(id/name/size_mb)与核层对不上 —— 以核层为准,
   在这儿按真实形状收,别信那份类型。 */
type WhisperRow = {
  key: string;
  display_name: string;
  size_label: string;
  downloaded: boolean;
  downloaded_bytes: number;
};
/* 同理:whisper_deps 返回的是**可执行文件路径或 null**,不是 bool。 */
type WhisperDeps = { whisper: string | null; ffmpeg: string | null };

const TR_ENGINES = [
  { id: "openai", label: "AI · OpenAI 格式" },
  { id: "anthropic", label: "AI · Anthropic 格式" },
  { id: "baiduGeneral", label: "百度翻译 · 通用" },
  { id: "baiduLlm", label: "百度翻译 · 大模型" },
  { id: "tencent", label: "腾讯机器翻译" },
];
/* 目标语言:core lang::norm 认这些基准码(zh-hans/zh-hant/en/ja/…)。 */
const TR_LANGS = [
  { id: "zh-hans", label: "简体中文" },
  { id: "zh-hant", label: "繁体中文" },
  { id: "en", label: "English" },
  { id: "ja", label: "日本語" },
  { id: "ko", label: "한국어" },
  { id: "fr", label: "Français" },
  { id: "de", label: "Deutsch" },
  { id: "es", label: "Español" },
  { id: "ru", label: "Русский" },
];

function SubTransPane() {
  const f = useFlash();
  const [s, setS] = useState<TrSettings | null>(null);
  const [st, setSt] = useState<Record<string, boolean>>({});
  const [models, setModels] = useState<WhisperRow[] | null>(null);
  const [deps, setDeps] = useState<WhisperDeps | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  /** 下载进度 0~100:模型下 1~3GB,不报进度用户会以为卡死(core 的注释也这么说)。 */
  const [prog, setProg] = useState<{ what: string; pct: number } | null>(null);

  const refreshWhisper = async () => {
    // 并发:两者互不依赖,串行只是白等一轮。
    const [m, d] = await Promise.all([whisperModels(), whisperDeps()]);
    setModels(m as unknown as WhisperRow[]);
    setDeps(d as unknown as WhisperDeps);
  };

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        /* ★ 四个 invoke 全并发,别串行 await。
           用户 2026-07-15 报「每次打开设置的字幕翻译每次都会卡」:
           核层那边是元凶(whisper_deps 同步 spawn 子进程 + 命令跑在主线程,已改 async+缓存),
           但这里串行 await 把四次往返摞成一条链,等于把那个卡再放大四倍。 */
        const [cur, status, m, d] = await Promise.all([
          getTranslationSettings(),
          translationEngineStatus(),
          whisperModels(),
          whisperDeps(),
        ]);
        if (!alive) return;
        setS(cur as unknown as TrSettings);
        setSt(status);
        setModels(m as unknown as WhisperRow[]);
        setDeps(d as unknown as WhisperDeps);
      } catch (e) {
        f.err(e);
      }
    })();
    /* core 用 emit 推下载进度(whisper-download / ffmpeg-download,载荷 [done,total,pct])。
       listen 是异步注册,卸载时要 await 到 unlisten 再摘,否则漏监听。 */
    const off: Array<() => void> = [];
    listen<[number, number, number]>("whisper-download", (e) =>
      setProg({ what: "模型", pct: e.payload[2] }),
    ).then((u) => (alive ? off.push(u) : u()));
    listen<[number, number, number]>("ffmpeg-download", (e) =>
      setProg({ what: "ffmpeg", pct: e.payload[2] }),
    ).then((u) => (alive ? off.push(u) : u()));
    return () => {
      alive = false;
      off.forEach((u) => u());
    };
  }, []);

  /** 改完即存 + 重读状态点(engine_status 是从**磁盘**重新 load 的,不存就永远是旧的)。 */
  async function commit(patch: Partial<TrSettings>) {
    if (!s) return;
    const next = { ...s, ...patch };
    setS(next);
    try {
      await setTranslationSettings(next);
      setSt(await translationEngineStatus());
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }
  /** 输入框:边打字只动本地态,blur 才落盘(照 PlaybackPane 的 onBlur 模式)。 */
  const edit = (patch: Partial<TrSettings>) => setS((p) => (p ? { ...p, ...patch } : p));

  async function dl(key: string) {
    if (busy) return;
    setBusy(key);
    setProg({ what: "模型", pct: 0 });
    try {
      await whisperDownload(key);
      await refreshWhisper();
      f.ok("模型已下载");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
      setProg(null);
    }
  }
  async function rm(key: string) {
    if (busy) return;
    setBusy(key);
    try {
      await whisperDelete(key);
      await refreshWhisper();
      f.ok("模型已删除");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }
  async function getFfmpeg() {
    if (busy) return;
    setBusy("ffmpeg");
    setProg({ what: "ffmpeg", pct: 0 });
    try {
      /* Linux 是 .tar.xz、core 解不了会返明确错误 —— 原样抛给用户,别吞成「失败」。 */
      await whisperDownloadFfmpeg();
      await refreshWhisper();
      f.ok("ffmpeg 已就绪");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
      setProg(null);
    }
  }

  if (!s) {
    /* f.node 必须挂在**加载分支里**:读取失败时 s 恒为 null,若这里不挂,
       错误 toast 根本没被 mount —— 用户只看到「读取中…」转到天荒地老,
       真正的原因被界面吞了。下面 CF / 多线程加载同理。 */
    return (
      <div className="mdpane">
        <h4>字幕翻译</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  const ai = s.engine === "openai" || s.engine === "anthropic";
  const baidu = s.engine === "baiduGeneral" || s.engine === "baiduLlm";
  const aiCfg = s.engine === "anthropic" ? s.anthropic : s.openai;
  const bdCfg = s.engine === "baiduLlm" ? s.baiduLlm : s.baiduGeneral;
  const setAi = (o: Partial<AiCfg>, save: boolean) => {
    const v = { ...aiCfg, ...o };
    (save ? commit : edit)(s.engine === "anthropic" ? { anthropic: v } : { openai: v });
  };
  const setBd = (o: Partial<BaiduCfg>, save: boolean) => {
    const v = { ...bdCfg, ...o };
    (save ? commit : edit)(s.engine === "baiduLlm" ? { baiduLlm: v } : { baiduGeneral: v });
  };
  const setTx = (o: Partial<TencentCfg>, save: boolean) =>
    (save ? commit : edit)({ tencent: { ...s.tencent, ...o } });

  return (
    <div className="mdpane">
      <h4>字幕翻译</h4>
      <p className="hint">
        字幕实时翻译 / 双语叠加。选一个引擎并填好密钥,状态点变绿即可用。
      </p>

      <div className="fld">
        <label>翻译引擎</label>
        <select
          className="field"
          style={{ cursor: "pointer" }}
          value={s.engine}
          onChange={(e) => commit({ engine: e.target.value })}
        >
          {TR_ENGINES.map((e) => (
            <option key={e.id} value={e.id}>
              {e.label}
            </option>
          ))}
        </select>
      </div>

      {/* 状态点:key 就是引擎 storage_key,绿=已配好(core build_engine 认它) */}
      <div className="st-dots">
        {TR_ENGINES.map((e) => (
          <span className="st-dotrow" key={e.id}>
            <i className={"st-dot" + (st[e.id] ? " on" : "")} />
            {e.label}
          </span>
        ))}
      </div>

      <div className="fld">
        <label>目标语言</label>
        <select
          className="field"
          style={{ cursor: "pointer" }}
          value={s.targetLang}
          onChange={(e) => commit({ targetLang: e.target.value })}
        >
          {TR_LANGS.map((l) => (
            <option key={l.id} value={l.id}>
              {l.label}
            </option>
          ))}
        </select>
      </div>

      <Row t="双语排版" d="译文与原文的上下关系">
        <Seg
          value={s.layout}
          opts={[
            { id: "translatedOnly", label: "仅译文" },
            { id: "translatedFirst", label: "译文在上" },
            { id: "originalFirst", label: "原文在上" },
          ]}
          onChange={(layout) => commit({ layout })}
        />
      </Row>

      <h4 style={{ marginTop: 20 }}>{TR_ENGINES.find((e) => e.id === s.engine)?.label} · 密钥</h4>
      <p className="hint">
        密钥与服务器 token 同等姿态<b>明文存本地配置文件</b>(核心行为,此端不另加密)。改完离开输入框即保存。
      </p>

      {ai && (
        <>
          <div className="fld">
            <label>接口地址</label>
            <input
              className="field"
              placeholder="https://api.openai.com/v1"
              value={aiCfg.baseUrl}
              onChange={(e) => setAi({ baseUrl: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>API Key</label>
            <input
              className="field"
              type="password"
              placeholder="sk-…"
              value={aiCfg.apiKey}
              onChange={(e) => setAi({ apiKey: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>模型</label>
            <input
              className="field"
              placeholder="gpt-4o-mini"
              value={aiCfg.model}
              onChange={(e) => setAi({ model: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      {baidu && (
        <>
          <div className="fld">
            <label>APP ID</label>
            <input
              className="field"
              placeholder="百度翻译开放平台的 APPID"
              value={bdCfg.appId}
              onChange={(e) => setBd({ appId: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          {s.engine === "baiduGeneral" ? (
            <div className="fld">
              <label>密钥</label>
              <input
                className="field"
                type="password"
                placeholder="通用接口的密钥(签名用)"
                value={bdCfg.secretKey}
                onChange={(e) => setBd({ secretKey: e.target.value }, false)}
                onBlur={() => commit({})}
              />
            </div>
          ) : (
            <div className="fld">
              <label>API Key</label>
              <input
                className="field"
                type="password"
                placeholder="大模型接口的 Bearer API Key"
                value={bdCfg.apiKey}
                onChange={(e) => setBd({ apiKey: e.target.value }, false)}
                onBlur={() => commit({})}
              />
            </div>
          )}
          <div className="fld">
            <label>接口地址(可选)</label>
            <input
              className="field"
              placeholder="留空用官方地址"
              value={bdCfg.endpoint}
              onChange={(e) => setBd({ endpoint: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      {s.engine === "tencent" && (
        <>
          <div className="fld">
            <label>SecretId</label>
            <input
              className="field"
              value={s.tencent.secretId}
              onChange={(e) => setTx({ secretId: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>SecretKey</label>
            <input
              className="field"
              type="password"
              value={s.tencent.secretKey}
              onChange={(e) => setTx({ secretKey: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>地域</label>
            <input
              className="field"
              placeholder="ap-beijing"
              value={s.tencent.region}
              onChange={(e) => setTx({ region: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      <h4 style={{ marginTop: 22 }}>Whisper 离线转写</h4>
      <p className="hint">
        无字幕的片子先本地转写出原文再翻译。需要 whisper-cli 与 ffmpeg 两个可执行文件,
        模型按需下载(不预置)。
      </p>
      <Row t="启用 Whisper 转写">
        <Sw on={s.whisperEnabled} onChange={(v) => commit({ whisperEnabled: v })} />
      </Row>

      {/* 依赖状态:核层返回的是**路径或 null**,有路径才算就位 */}
      <div className="st-dots">
        <span className="st-dotrow">
          <i className={"st-dot" + (deps?.whisper ? " on" : "")} />
          whisper-cli {deps?.whisper ? "已就位" : "未找到"}
        </span>
        <span className="st-dotrow">
          <i className={"st-dot" + (deps?.ffmpeg ? " on" : "")} />
          ffmpeg {deps?.ffmpeg ? "已就位" : "未找到"}
          {!deps?.ffmpeg && (
            <button className="btn sm" disabled={!!busy} onClick={getFfmpeg} style={{ marginLeft: 10 }}>
              {busy === "ffmpeg" ? "下载中…" : "自动下载"}
            </button>
          )}
        </span>
      </div>

      <Row t="转写模型" d="越大越准也越慢;选中的档位需先下载">
        <Seg
          value={s.whisperModel}
          opts={[
            { id: "tiny", label: "Tiny" },
            { id: "base", label: "Base" },
            { id: "medium", label: "Medium" },
            { id: "large", label: "Large" },
          ]}
          onChange={(v) => commit({ whisperModel: v })}
        />
      </Row>

      {models?.map((m) => (
        <Row
          key={m.key}
          t={m.display_name}
          d={m.downloaded ? `已下载 · ${fmtSize(m.downloaded_bytes)}` : m.size_label}
        >
          {m.downloaded ? (
            <button className="btn" disabled={!!busy} onClick={() => rm(m.key)}>
              删除
            </button>
          ) : (
            <button className="btn primary" disabled={!!busy} onClick={() => dl(m.key)}>
              {busy === m.key ? "下载中…" : "下载"}
            </button>
          )}
        </Row>
      ))}

      {prog && (
        <div className="st-prog">
          <span className="spinner" /> 正在下载{prog.what} {prog.pct.toFixed(1)}%
          <span className="bar">
            <i style={{ width: `${Math.min(100, prog.pct)}%` }} />
          </span>
        </div>
      )}

      <div className="fld" style={{ marginTop: 14 }}>
        <label>模型下载镜像(可选)</label>
        <input
          className="field"
          placeholder="留空用 Hugging Face 官方源"
          value={s.whisperMirror}
          onChange={(e) => edit({ whisperMirror: e.target.value })}
          onBlur={() => commit({})}
        />
      </div>
      <div className="fld">
        <label>whisper-cli 路径(可选)</label>
        <input
          className="field"
          placeholder="留空自动定位"
          value={s.whisperBinary}
          onChange={(e) => edit({ whisperBinary: e.target.value })}
          onBlur={() => commit({}).then(refreshWhisper)}
        />
      </div>
      <div className="fld">
        <label>ffmpeg 路径(可选)</label>
        <input
          className="field"
          placeholder="留空自动定位"
          value={s.ffmpegPath}
          onChange={(e) => edit({ ffmpegPath: e.target.value })}
          onBlur={() => commit({}).then(refreshWhisper)}
        />
      </div>
      {f.node}
    </div>
  );
}

/* ============================================================
   网络 · CF 优选加速
   服务器的身份键就是 **account.server**(核层 cfg.find(server_id) 比的是 a.server),
   不是 user_id、也不是 line_url —— 传错核层只会「找不到该服务器」。
   开/关都是热生效(核层内部 refresh_session_base),此处不必提示重启。
   ============================================================ */
function CfPane() {
  const f = useFlash();
  const [accts, setAccts] = useState<AccountInfo[] | null>(null);
  const [rows, setRows] = useState<CfProxyStatus[]>([]);
  const [ips, setIps] = useState<CfTestResult[] | null>(null);
  const [pick, setPick] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  /** 只对这台服测速:validate_host 用它的域名剔掉「TCP 通但 HTTP 死」的边缘。 */
  const [target, setTarget] = useState("");

  const reload = async () => {
    const [a, r] = await Promise.all([listAccounts(), cfProxyStatus()]);
    setAccts(a);
    setRows(r);
    setTarget((t) => t || a[0]?.server || "");
  };

  useEffect(() => {
    reload().catch(f.err);
  }, []);

  const cur = accts?.find((a) => a.server === target);

  async function test() {
    if (busy) return;
    setBusy("test");
    setIps(null);
    try {
      /* 测速要拿**直连**线路的域名去校验:line_url 就是未经反代改写的上游。 */
      const res = await cfSpeedTest(hostOf(cur?.line_url ?? "") || null, null);
      setIps(res);
      setPick(res[0]?.ip ?? "");
      f.ok(res.length ? `测到 ${res.length} 个可用 IP` : "没测到可用 IP");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function enable(serverId: string, ip: string) {
    if (busy || !ip) return;
    setBusy(serverId);
    try {
      const url = await cfProxyEnable(serverId, ip);
      await reload();
      f.ok(`已启用 · ${url}`);
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function disable(serverId: string) {
    if (busy) return;
    setBusy(serverId);
    try {
      await cfProxyDisable(serverId);
      await reload();
      f.ok("已关闭,恢复直连");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  if (!accts) {
    return (
      <div className="mdpane">
        <h4>CF 优选加速</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  return (
    <div className="mdpane">
      <h4>CF 优选加速</h4>
      <p className="hint">
        测出延迟低的 Cloudflare 边缘 IP,起一个本地反代把该服务器的 API / 封面 / 取流
        全部钉到这个 IP。开关即时生效,无需重启。
      </p>

      {accts.length === 0 && <p className="hint">还没有服务器,先去服务器页添加。</p>}

      {accts.length > 0 && (
        <>
          <div className="fld">
            <label>为哪台服务器优选</label>
            <select
              className="field"
              style={{ cursor: "pointer" }}
              value={target}
              onChange={(e) => {
                setTarget(e.target.value);
                setIps(null); // 换服就得重测:上一台的结果对这台没有参考意义
              }}
            >
              {accts.map((a) => (
                <option key={a.server} value={a.server}>
                  {a.name || hostOf(a.server) || a.server}
                </option>
              ))}
            </select>
          </div>

          <div className="st-actions" style={{ marginTop: 8 }}>
            <button className="btn primary" disabled={!!busy || !cur} onClick={test}>
              {busy === "test" ? "测速中…" : "开始测速"}
            </button>
            {busy === "test" && <span className="spinner" />}
            {f.node}
          </div>
        </>
      )}

      {ips && ips.length > 0 && (
        <>
          <div className="fld" style={{ marginTop: 14 }}>
            <label>候选 IP(已按优劣排序,最优在前)</label>
            <select
              className="field"
              style={{ cursor: "pointer" }}
              value={pick}
              onChange={(e) => setPick(e.target.value)}
            >
              {ips.map((r) => (
                <option key={r.ip} value={r.ip}>
                  {r.ip} · {r.latency_ms}ms · 丢包 {(r.loss_rate * 100).toFixed(0)}%
                  {r.download_kbps ? ` · ${(r.download_kbps / 1024).toFixed(1)} MB/s` : ""}
                </option>
              ))}
            </select>
          </div>
          <div className="st-actions" style={{ marginTop: 8 }}>
            <button
              className="btn primary"
              disabled={!!busy || !pick || !cur}
              onClick={() => cur && enable(cur.server, pick)}
            >
              {busy === cur?.server ? "启用中…" : "启用此 IP"}
            </button>
          </div>
        </>
      )}
      {ips && ips.length === 0 && (
        <p className="hint" style={{ marginTop: 12 }}>
          没测到可用 IP —— 可能是网络封锁或该服务器不在 Cloudflare 后面。
        </p>
      )}

      <h4 style={{ marginTop: 22 }}>当前生效的优选</h4>
      {rows.length === 0 ? (
        <p className="hint">还没有服务器在走优选,全部直连。</p>
      ) : (
        rows.map((r) => {
          const a = accts.find((x) => x.server === r.server_id);
          return (
            <Row
              key={r.server_id}
              t={a?.name || hostOf(r.server_id) || r.server_id}
              d={`钉住 ${r.pinned_ip || "(未知)"} · 本地反代 ${r.local_url}`}
            >
              <button className="btn" disabled={!!busy} onClick={() => disable(r.server_id)}>
                {busy === r.server_id ? "处理中…" : "关闭"}
              </button>
            </Row>
          );
        })
      )}
    </div>
  );
}

/* ============================================================
   网络 · 多线程加载(预取代理)
   本地起代理超前拉 Range 喂播放器。核层对 threads(2~4)/cache_bytes(≥16MB)
   是**拒绝**不是夹紧 —— 所以这里绝不能先把值 clamp 好再提交:那样用户点到上限
   会毫无反应,而错误信息(「预取线程数只支持 2~4」)正是唯一的反馈来源。
   Stepper 的 min/max 只做常规引导,越界一律让核层说话。
   ============================================================ */
const MB = 1024 * 1024;
function PrefetchPane() {
  const f = useFlash();
  const [s, setS] = useState<PrefetchSettings | null>(null);

  useEffect(() => {
    let alive = true;
    getPrefetchSettings()
      .then((v) => alive && setS(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /** 改完即存;核层拒了就回滚 UI 并把原话弹出来。 */
  async function commit(patch: Partial<PrefetchSettings>) {
    if (!s) return;
    const prev = s;
    const next = { ...s, ...patch };
    setS(next);
    try {
      await setPrefetchSettings(next);
      f.ok("已保存");
    } catch (e) {
      setS(prev);
      f.err(e);
    }
  }

  if (!s) {
    return (
      <div className="mdpane">
        <h4>多线程加载</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  return (
    <div className="mdpane">
      <h4>多线程加载</h4>
      <p className="hint">
        本地预取代理:播放器走 127.0.0.1,由代理并发 Range 超前拉流再喂给它,
        缓解边下边播的卡顿。只对 Emby 直传流生效(直链 / 转码流会跳过)。
      </p>
      {/* 默认关,且必须当面告诉用户为什么 —— 悄悄关掉等于把一个已知缺陷藏起来。 */}
      <p className="hint st-warn">
        ⚠ 默认关闭:实测开启后部分影片会「有流量但黑屏无声、一直缓冲」(尤其带大字体
        附件、索引在文件末尾的 MKV)。原因是每次跳转都会丢弃已下好的缓存并反复重下。
        修好之前请保持关闭;开了放不出来,先把它关回去。
      </p>
      <Row t="启用多线程加载" d="已知缺陷,建议保持关闭">
        <Sw on={s.enabled} onChange={(enabled) => commit({ enabled })} />
      </Row>
      <Row t="并发线程数" d="核心只接受 2~4;超出会被拒绝并提示">
        <Stepper
          value={s.threads}
          min={1}
          max={5}
          step={1}
          fmt={(v) => String(v)}
          onChange={(threads) => commit({ threads })}
        />
      </Row>
      <Row t="读前缓冲上限" d="核心要求不低于 16MB">
        <Stepper
          value={s.cache_bytes / MB}
          min={8}
          max={512}
          step={16}
          fmt={(v) => `${v} MB`}
          onChange={(v) => commit({ cache_bytes: v * MB })}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   网络 · 代理设置
   ============================================================ */
const PROXY_TYPES: { id: string; label: string }[] = [
  { id: "none", label: "直连" },
  { id: "http", label: "HTTP" },
  { id: "https", label: "HTTPS" },
  { id: "socks5", label: "SOCKS5" },
  { id: "socks4", label: "SOCKS4" },
];
function ProxyPane() {
  const f = useFlash();
  const [type, setType] = useState("none");
  const [host, setHost] = useState("");
  const [port, setPort] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [proxyMedia, setProxyMedia] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const off = type === "none";

  useEffect(() => {
    let alive = true;
    getProxy()
      .then((c) => {
        if (!alive) return;
        setType(c.type || "none");
        setHost(c.host);
        setPort(c.port ? String(c.port) : "");
        setUsername(c.username);
        setPassword(c.password);
        setProxyMedia(c.proxy_media);
        setLoaded(true);
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /* pin 31「改完即生效」:输入框 blur、分段/开关点按即落盘,不留「保存」按钮。
     原先「播放流也走代理」只 setState 不落盘 —— 拨一下走开就没了,还什么都不报。
     所有 setter 都必须经过这里,别再出现只动 React 态的分支。 */
  async function save(next?: Partial<ProxyConfig>) {
    if (!loaded) return; // 读回来之前别用初值把磁盘上的配置覆盖成空
    try {
      await setProxy({
        type,
        host: host.trim(),
        port: Number(port) || 0,
        username: username.trim(),
        password,
        proxy_media: proxyMedia,
        ...next,
      });
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>代理设置</h4>
      <p className="hint">
        为元数据与登录请求走代理。选「直连」则不走代理。改完离开输入框即保存。
      </p>
      <div className="fld">
        <label>代理类型</label>
        <Seg
          value={type}
          opts={PROXY_TYPES}
          onChange={(v) => {
            setType(v);
            save({ type: v });
          }}
        />
      </div>
      <div className="fld">
        <label>服务器</label>
        <div style={{ display: "flex", gap: 10 }}>
          <input
            className="field"
            placeholder="127.0.0.1"
            value={host}
            disabled={off || !loaded}
            onChange={(e) => setHost(e.target.value)}
            onBlur={() => save()}
          />
          <input
            className="field"
            style={{ flex: "0 0 110px" }}
            placeholder="7890"
            inputMode="numeric"
            value={port}
            disabled={off || !loaded}
            onChange={(e) => setPort(e.target.value.replace(/[^0-9]/g, ""))}
            onBlur={() => save()}
          />
        </div>
      </div>
      <div className="fld">
        <label>认证(可选)</label>
        <div style={{ display: "flex", gap: 10 }}>
          <input
            className="field"
            placeholder="用户名"
            value={username}
            disabled={off || !loaded}
            onChange={(e) => setUsername(e.target.value)}
            onBlur={() => save()}
          />
          <input
            className="field"
            type="password"
            placeholder="密码"
            value={password}
            disabled={off || !loaded}
            onChange={(e) => setPassword(e.target.value)}
            onBlur={() => save()}
          />
        </div>
      </div>
      <Row t="播放流也走代理" d="开启后视频流量也经代理(可能拖慢直连)">
        <Sw
          on={proxyMedia}
          disabled={off || !loaded}
          onChange={(v) => {
            setProxyMedia(v);
            save({ proxy_media: v });
          }}
        />
      </Row>
      <div className="st-actions">{f.node}</div>
    </div>
  );
}

/* ============================================================
   同步 · 同步记录 · 跨服聚合
   跨服续播开关(核层默认**关**)+ 回传三项。回传 range 核层对未知值是**拒绝**
   不是回落 —— 因为静默回落 "all" 会让选了「仅初次」的用户在写所有服务器。
   所以错误必须原样弹出来。

   ponytail: 观看记录列表(watch_history_list/delete)本该也在这个面板里,但 api.ts
   的这两个绑定与核层对不上、**调用必然报错**,而本任务不许改 api.ts:
     · watch_history_list 核层签名是 (current_only: bool),api.ts 一个参数都没传;
     · watch_history_delete 核层参数是 record_id(线上 recordId),api.ts 传的是 key。
   宁可先不做,也不做一个一进来就报错的列表 —— 等 api.ts 修好再补,别在这儿绕过封装。
   ============================================================ */
const WB_RANGES = [
  { id: "all", label: "所有服务器" },
  { id: "first", label: "仅初次" },
  { id: "latest", label: "仅最新" },
];
function SyncPane() {
  const f = useFlash();
  const [resume, setResume] = useState<boolean | null>(null);
  const [wb, setWb] = useState<WritebackSettings | null>(null);

  useEffect(() => {
    let alive = true;
    getCrossServerResume()
      .then((v) => alive && setResume(v))
      .catch(f.err);
    getWritebackSettings()
      .then((v) => alive && setWb(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function toggleResume(v: boolean) {
    const prev = resume;
    setResume(v);
    try {
      await setCrossServerResume(v);
      f.ok("已保存");
    } catch (e) {
      setResume(prev);
      f.err(e);
    }
  }

  async function commitWb(patch: Partial<WritebackSettings>) {
    if (!wb) return;
    const prev = wb;
    const next = { ...wb, ...patch };
    setWb(next);
    try {
      await setWritebackSettings(next);
      f.ok("已保存");
    } catch (e) {
      setWb(prev); // 被拒了就退回去,别让 UI 显示一个没存进去的选项
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>同步记录 · 跨服聚合</h4>
      <p className="hint">
        同一部片存在于多台服务器时,如何合并观看进度与已看状态。
      </p>

      <Row t="跨服务器续播" d="在任意一台看过,换台服务器接着看(取最大进度)。默认关闭">
        <Sw on={resume ?? false} disabled={resume === null} onChange={toggleResume} />
      </Row>

      <h4 style={{ marginTop: 20 }}>观看状态回传</h4>
      <p className="hint">看完一集后,把已看状态回写到其它拥有同一部片的服务器。</p>
      <Row t="启用回传">
        <Sw
          on={wb?.enabled ?? false}
          disabled={!wb}
          onChange={(enabled) => commitWb({ enabled })}
        />
      </Row>
      <Row t="回传范围" d="回写到哪些服务器">
        <Seg
          value={wb?.range ?? "all"}
          opts={WB_RANGES}
          onChange={(range) => commitWb({ range })}
        />
      </Row>
      <Row t="连播放进度一起回传" d="关闭则只回传「已看 / 未看」,不同步具体秒数">
        <Sw
          on={wb?.include_progress ?? false}
          disabled={!wb}
          onChange={(include_progress) => commitWb({ include_progress })}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   同步 · Trakt / Bangumi
   ============================================================ */
function TraktBlock() {
  const f = useFlash();
  const [acct, setAcct] = useState<SyncAccount | null>(null);
  const [code, setCode] = useState<TraktDeviceCode | null>(null);
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const stopPoll = () => {
    if (timer.current) clearInterval(timer.current);
    timer.current = null;
  };

  useEffect(() => {
    traktAccount().then(setAcct).catch(f.err);
    return stopPoll; // 卸载清定时器
  }, []);

  async function connect() {
    if (busy) return;
    setBusy(true);
    try {
      const dc = await traktDeviceCode();
      setCode(dc);
      stopPoll();
      timer.current = setInterval(async () => {
        try {
          const r = await traktPoll(dc.device_code);
          if (r.account) {
            stopPoll();
            setCode(null);
            setAcct(await traktAccount());
            f.ok("Trakt 已连接");
          }
        } catch (e) {
          stopPoll();
          setCode(null);
          f.err(e);
        }
      }, Math.max(1, dc.interval) * 1000);
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function disconnect() {
    try {
      await traktLogout();
      setAcct(null);
      f.ok("已断开 Trakt");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <>
      <Row t="Trakt" d={acct ? `已连接 · ${acct.username ?? "已授权"}` : "自动同步观看进度与收藏"}>
        {acct ? (
          <button className="btn" onClick={disconnect}>
            断开
          </button>
        ) : (
          <button className="btn primary" disabled={busy || !!code} onClick={connect}>
            {busy ? "获取中…" : "连接"}
          </button>
        )}
      </Row>
      {code && (
        <div className="st-auth">
          <p className="hint" style={{ margin: "0 0 10px" }}>
            浏览器打开下方地址,输入验证码完成授权:
          </p>
          <div className="st-copyrow" style={{ marginBottom: 12 }}>
            <input className="field" readOnly value={code.verification_url} />
            <button
              className="btn"
              onClick={() => {
                copy(code.verification_url);
                f.ok("已复制");
              }}
            >
              复制
            </button>
          </div>
          <div className="st-code">{code.user_code}</div>
          <div className="st-poll">
            <span className="spinner" /> 等待授权中,授权后自动完成…
          </div>
        </div>
      )}
      {f.node}
    </>
  );
}

function BangumiBlock() {
  const f = useFlash();
  const [acct, setAcct] = useState<SyncAccount | null>(null);
  const [authUrl, setAuthUrl] = useState("");
  const [code, setCode] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    bangumiAccount().then(setAcct).catch(f.err);
  }, []);

  async function begin() {
    if (busy) return;
    setBusy(true);
    try {
      setAuthUrl(await bangumiAuthorizeUrl());
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function submit() {
    if (busy || !code.trim()) return;
    setBusy(true);
    try {
      await bangumiExchange(code.trim());
      setAcct(await bangumiAccount());
      setAuthUrl("");
      setCode("");
      f.ok("Bangumi 已连接");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function disconnect() {
    try {
      await bangumiLogout();
      setAcct(null);
      f.ok("已断开 Bangumi");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <>
      <Row t="Bangumi" d={acct ? `已连接 · ${acct.username ?? "已授权"}` : "同步在看状态与收藏"}>
        {acct ? (
          <button className="btn" onClick={disconnect}>
            断开
          </button>
        ) : (
          <button className="btn primary" disabled={busy || !!authUrl} onClick={begin}>
            {busy ? "获取中…" : "连接"}
          </button>
        )}
      </Row>
      {authUrl && (
        <div className="st-auth">
          <p className="hint" style={{ margin: "0 0 10px" }}>
            浏览器打开授权地址,授权后把回调里的 code 粘到下方提交:
          </p>
          <div className="st-copyrow" style={{ marginBottom: 12 }}>
            <input className="field" readOnly value={authUrl} />
            <button
              className="btn"
              onClick={() => {
                copy(authUrl);
                f.ok("已复制");
              }}
            >
              复制
            </button>
          </div>
          <div className="st-copyrow">
            <input
              className="field"
              placeholder="粘贴授权 code"
              value={code}
              onChange={(e) => setCode(e.target.value)}
            />
            <button className="btn primary" disabled={busy || !code.trim()} onClick={submit}>
              提交
            </button>
          </div>
        </div>
      )}
      {f.node}
    </>
  );
}

function AccountPane() {
  return (
    <div className="mdpane">
      <h4>Trakt / Bangumi</h4>
      <p className="hint">连接第三方追剧服务,观看进度与收藏自动同步。</p>
      <TraktBlock />
      <BangumiBlock />
    </div>
  );
}

/* ============================================================
   同步 · 追剧日历 —— 付费功能说明(诚实占位)
   ============================================================ */
function CalendarPane({ onOpen }: { onOpen: () => void }) {
  return (
    <div className="mdpane">
      <h4>追剧日历</h4>
      <p className="hint">
        Trakt / Bangumi 一周放送表 —— 付费功能,爱发电赞助后用订单号解锁(解锁入口在日历页内)。
      </p>
      <div className="setrow">
        <div className="l">
          <div className="t">打开追剧日历</div>
          <div className="d">按周查看已登录账号的放送表。</div>
        </div>
        <div className="ctl">
          <button className="btn primary sm" onClick={onOpen}>
            打开
          </button>
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   其它 · 插件
   包格式是 **.ipk**(core installer.rs:「.ipk(就是 zip,含 manifest.json + main.js)」),
   不是 .lpk —— 提示语别写错,用户会照着去找文件。
   安装后核层默认**禁用**,要用户自己开(权限得先过目)。

   ponytail: 用路径输入框而非文件选择器 —— @tauri-apps/plugin-dialog 不在依赖里,
   为一个安装入口拉一个 npm + Rust 插件不值。要原生选择器就先装那个依赖。
   ============================================================ */
type Plugin = {
  id: string;
  name: string;
  version: string;
  author?: string;
  description?: string;
  enabled: boolean;
  error?: string | null;
};
function PluginsPane() {
  const f = useFlash();
  const [list, setList] = useState<Plugin[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [path, setPath] = useState("");

  const load = () =>
    pluginList()
      .then((l) => setList(l as unknown as Plugin[]))
      .catch((e) => {
        setList([]);
        f.err(e);
      });

  useEffect(() => {
    load();
  }, []);

  async function toggle(p: Plugin) {
    if (busy) return;
    setBusy(p.id);
    try {
      await (p.enabled ? pluginDisable(p.id) : pluginEnable(p.id));
      await load();
      f.ok(p.enabled ? "已停用" : "已启用");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function install() {
    const p = path.trim();
    if (busy || !p) return;
    setBusy("install");
    try {
      const info = (await pluginInstall(p)) as unknown as Plugin;
      await load();
      setPath("");
      f.ok(`已安装 ${info.name ?? ""} —— 默认停用,确认权限后再启用`);
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function uninstall(p: Plugin) {
    if (busy) return;
    setBusy(p.id);
    try {
      await pluginUninstall(p.id);
      await load();
      f.ok("已卸载");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="mdpane">
      <h4>插件</h4>
      <p className="hint">安装 .ipk 插件包,并管理已装插件的启用 / 停用。</p>

      {list == null ? (
        <div className="empty" style={{ padding: "28px 0" }}>
          <span className="spinner" />
        </div>
      ) : list.length === 0 ? (
        <div className="empty" style={{ padding: "28px 0" }}>
          还没有安装插件 —— 在下方填 .ipk 路径安装。
        </div>
      ) : (
        list.map((p) => (
          <div className="st-card" key={p.id}>
            <div className="setrow">
              <span className="l">
                <span className="t">{p.name}</span>
                <span className="d">
                  v{p.version}
                  {p.author ? " · " + p.author : ""}
                  {p.error ? ` · 加载出错:${p.error}` : ""}
                </span>
              </span>
              <span className="ctl" style={{ display: "flex", gap: 10, alignItems: "center" }}>
                <Sw on={p.enabled} disabled={busy === p.id} onChange={() => toggle(p)} />
                <button className="btn" disabled={busy === p.id} onClick={() => uninstall(p)}>
                  卸载
                </button>
              </span>
            </div>
          </div>
        ))
      )}

      <h4 style={{ marginTop: 18 }}>安装插件</h4>
      <p className="hint">填 .ipk 文件的完整路径。安装后默认停用,确认权限后再启用。</p>
      <div className="st-copyrow">
        <input
          className="field"
          placeholder="D:\插件\com.example.plugin.ipk"
          value={path}
          onChange={(e) => setPath(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && install()}
        />
        <button className="btn primary" disabled={!!busy || !path.trim()} onClick={install}>
          {busy === "install" ? "安装中…" : "安装"}
        </button>
      </div>
      <div className="st-actions">{f.node}</div>
    </div>
  );
}

/* ============================================================
   其它 · 更新 · 备份 · 关于
   ============================================================ */
function AboutPane() {
  const f = useFlash();
  const [payload, setPayload] = useState("");
  const [qr, setQr] = useState("");
  const [qrErr, setQrErr] = useState("");
  const [importText, setImportText] = useState("");
  const [busyOut, setBusyOut] = useState(false);
  const [busyIn, setBusyIn] = useState(false);

  async function doExport() {
    if (busyOut) return;
    setBusyOut(true);
    setQr("");
    setQrErr("");
    try {
      const p = await configExportQr();
      setPayload(p);
      /* 核层的 config_export_qr 就是给「前端渲染成二维码」用的。
         但载荷是 AES+gzip 的服务器配置,账号一多就会超出二维码容量上限
         (纠错级 L 也就 ~2.9KB)—— toDataURL 会直接 reject。
         那不是 bug 是物理上限:此时如实说明并留文本载荷兜底,别静默不出图。 */
      try {
        setQr(await QRCode.toDataURL(p, { errorCorrectionLevel: "L", margin: 1, width: 260 }));
      } catch (e) {
        setQrErr(String(e));
      }
      f.ok("已生成迁移载荷");
    } catch (e) {
      f.err(e);
    } finally {
      setBusyOut(false);
    }
  }

  async function doImport() {
    if (busyIn || !importText.trim()) return;
    setBusyIn(true);
    try {
      const n = await configImportQr(importText.trim());
      f.ok(`已导入 ${n} 个账号`);
      setImportText("");
    } catch (e) {
      f.err(e);
    } finally {
      setBusyIn(false);
    }
  }

  return (
    <div className="mdpane">
      <h4>更新 · 备份 · 关于</h4>
      <p className="hint">应用信息、配置备份与迁移。</p>

      <div className="st-kv">
        <span className="k">应用</span>
        <span className="v">LinPlayer</span>
      </div>
      <div className="st-kv">
        <span className="k">版本</span>
        <span className="v">0.1.0</span>
      </div>
      <div className="st-kv">
        <span className="k">技术栈</span>
        <span className="v">Rust 核 + Tauri + React</span>
      </div>
      <div className="st-kv">
        <span className="k">更新通道</span>
        <span className="v muted">开发预览,暂无更新通道</span>
      </div>

      <h4 style={{ marginTop: 22 }}>配置备份 · 迁移</h4>
      <p className="hint">
        在设备间搬运服务器配置(<b>含登录凭据</b>)—— 用另一台设备扫码,或复制文本载荷粘贴。
        二维码等同于账号密码,别外发、别截图上传。
      </p>
      <Row t="导出本机配置" d="生成 LPSYNC1 载荷,扫码或复制到另一台设备导入">
        <button className="btn" disabled={busyOut} onClick={doExport}>
          {busyOut ? "生成中…" : "导出"}
        </button>
      </Row>
      {qr && (
        <div className="st-qr">
          <img src={qr} alt="配置迁移二维码" width={260} height={260} />
          <p className="hint">用另一台设备的 LinPlayer 扫这个码即可搬运。</p>
        </div>
      )}
      {qrErr && (
        <p className="hint" style={{ marginTop: 12 }}>
          载荷太大,超出二维码容量上限,出不了图({qrErr})—— 用下面的文本载荷复制粘贴,
          或先删掉几台用不上的服务器再导出。
        </p>
      )}
      {payload && (
        <div className="fld" style={{ marginTop: 12 }}>
          <textarea className="field" readOnly rows={4} value={payload} />
          <div>
            <button
              className="btn"
              onClick={() => {
                copy(payload);
                f.ok("已复制到剪贴板");
              }}
            >
              复制载荷
            </button>
          </div>
        </div>
      )}
      <div className="fld" style={{ marginTop: 6 }}>
        <label>导入配置</label>
        <textarea
          className="field"
          rows={4}
          placeholder="粘贴另一台设备导出的 LPSYNC1:… 载荷"
          value={importText}
          onChange={(e) => setImportText(e.target.value)}
        />
        <div className="st-actions" style={{ marginTop: 8 }}>
          <button className="btn primary" disabled={busyIn || !importText.trim()} onClick={doImport}>
            {busyIn ? "导入中…" : "导入"}
          </button>
          {f.node}
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   左目录分组(照草稿:通用 / 网络 / 同步账号 / 其它)
   ============================================================ */
type ItemDef = { id: string; label: string; icon: ReactNode };
const SECTIONS: { sec: string; items: ItemDef[] }[] = [
  {
    sec: "通用",
    items: [
      { id: "appearance", label: "外观与语言", icon: <IconSun size={16} /> },
      { id: "playback", label: "播放器", icon: <IconPlay size={16} /> },
      { id: "danmaku", label: "弹幕", icon: <IconLibrary size={16} /> },
      { id: "subtrans", label: "字幕翻译", icon: <IconFile size={16} /> },
    ],
  },
  {
    sec: "网络",
    items: [
      { id: "cf", label: "CF 优选加速", icon: <IconCloud size={16} /> },
      { id: "prefetch", label: "多线程加载", icon: <IconRefresh size={16} /> },
      { id: "proxy", label: "代理设置", icon: <IconServer size={16} /> },
    ],
  },
  {
    sec: "同步 / 账号",
    items: [
      { id: "sync", label: "同步记录 · 跨服聚合", icon: <IconRefresh size={16} /> },
      { id: "account", label: "Trakt / Bangumi", icon: <IconHeart size={16} /> },
      { id: "calendar", label: "追剧日历", icon: <IconInfo size={16} /> },
    ],
  },
  {
    sec: "其它",
    items: [
      { id: "plugins", label: "插件", icon: <IconSettings size={16} /> },
      { id: "about", label: "更新 · 备份 · 关于", icon: <IconInfo size={16} /> },
    ],
  },
];

const LABELS: Record<string, string> = Object.fromEntries(
  SECTIONS.flatMap((s) => s.items).map((i) => [i.id, i.label]),
);

export default function SettingsPage({ theme, setTheme, onOpenCalendar }: Props) {
  const [active, setActive] = useState("appearance");
  const [q, setQ] = useState("");

  // 搜索:本地过滤左栏项(诚实 —— 仅筛目录,不搜项内文案)。
  const sections = useMemo(() => {
    const kw = q.trim().toLowerCase();
    if (!kw) return SECTIONS;
    return SECTIONS.map((s) => ({
      ...s,
      items: s.items.filter((i) => i.label.toLowerCase().includes(kw)),
    })).filter((s) => s.items.length);
  }, [q]);

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>设置</b>
          <span className="sep">›</span>
          {LABELS[active] ?? ""}
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={13} />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="搜索设置项…"
              style={{
                background: "transparent",
                border: "none",
                outline: "none",
                color: "var(--ink)",
                width: "100%",
                font: "inherit",
              }}
            />
          </label>
        </span>
      </div>

      <div className="scroll">
        <div className="cbody">
          <div className="md">
            <div className="mdnav">
              {sections.map((s) => (
                <div key={s.sec}>
                  <div className="sec">{s.sec}</div>
                  {s.items.map((it) => (
                    <button
                      key={it.id}
                      className={"it" + (active === it.id ? " on" : "")}
                      onClick={() => setActive(it.id)}
                    >
                      {it.icon}
                      {it.label}
                    </button>
                  ))}
                </div>
              ))}
            </div>

            {active === "appearance" && <AppearancePane theme={theme} setTheme={setTheme} />}
            {active === "playback" && <PlaybackPane />}
            {active === "danmaku" && <DanmakuPane />}
            {active === "subtrans" && <SubTransPane />}
            {active === "cf" && <CfPane />}
            {active === "prefetch" && <PrefetchPane />}
            {active === "proxy" && <ProxyPane />}
            {active === "sync" && <SyncPane />}
            {active === "account" && <AccountPane />}
            {active === "calendar" && <CalendarPane onOpen={onOpenCalendar} />}
            {active === "plugins" && <PluginsPane />}
            {active === "about" && <AboutPane />}
          </div>
        </div>
      </div>
    </>
  );
}
