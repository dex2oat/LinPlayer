import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./SettingsPage.css";
import {
  type ProxyConfig,
  type SyncAccount,
  type TraktDeviceCode,
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
   audio_lang / sub_lang / sub_enabled 真落 prefs;
   其余(解码/进度/跳过/缩略图/倍速/杜比/外部播放器)本机暂存,
   播放核未接入 —— 诚实标注,不造假。
   ============================================================ */
const LP_KEY = "lp.playback.local";
type LocalPlayback = {
  decode: "hw" | "sw";
  resume: boolean;
  skip: boolean;
  thumbs: boolean;
  speed: number;
  dolby: boolean;
  external: string;
};
const LP_DEFAULT: LocalPlayback = {
  decode: "hw",
  resume: true,
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
    return () => {
      alive = false;
    };
  }, []);

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
      <Row t="记忆播放进度 · 跨服续播">
        <Sw on={lp.resume} onChange={(resume) => patchLocal({ resume })} />
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
        以上解码 / 进度 / 倍速等为本机偏好,已存本地,播放核接入后生效(尚未影响实际播放)。
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
function DanmakuPane() {
  const f = useFlash();
  const [apiUrl, setApiUrl] = useState("");
  const [authType, setAuthType] = useState("none");
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    getDanmakuConfig()
      .then((c) => {
        if (!alive) return;
        setApiUrl(c.api_url);
        setAuthType(c.auth_type || "none");
        setToken(c.token);
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function save() {
    if (busy) return;
    setBusy(true);
    try {
      await setDanmakuConfig(apiUrl.trim(), authType, token.trim());
      f.ok("弹幕源已保存");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mdpane">
      <h4>弹幕</h4>
      <p className="hint">配置弹弹play 兼容的弹幕 API 地址与鉴权方式。</p>
      <div className="fld">
        <label>API 地址</label>
        <input
          className="field"
          placeholder="https://api.dandanplay.net"
          value={apiUrl}
          onChange={(e) => setApiUrl(e.target.value)}
        />
      </div>
      <div className="fld">
        <label>鉴权方式</label>
        <select
          className="field"
          style={{ cursor: "pointer" }}
          value={authType}
          onChange={(e) => setAuthType(e.target.value)}
        >
          {DANMAKU_AUTH.map((a) => (
            <option key={a.id} value={a.id}>
              {a.label}
            </option>
          ))}
        </select>
      </div>
      {authType !== "none" && (
        <div className="fld">
          <label>Token</label>
          <input
            className="field"
            placeholder="鉴权令牌"
            value={token}
            onChange={(e) => setToken(e.target.value)}
          />
        </div>
      )}
      <div className="st-actions">
        <button className="btn primary" disabled={busy} onClick={save}>
          {busy ? "保存中…" : "保存"}
        </button>
        {f.node}
      </div>
    </div>
  );
}

/* ============================================================
   通用 · 字幕翻译 —— 诚实占位
   ============================================================ */
function SubTransPane() {
  return (
    <div className="mdpane">
      <h4>字幕翻译</h4>
      <p className="hint">字幕实时翻译 / 双语叠加。</p>
      <div className="empty" style={{ padding: "28px 0" }}>
        字幕翻译尚未接入,待接。
      </div>
    </div>
  );
}

/* ============================================================
   网络 · CF 优选加速 —— 此端未接命令,诚实占位
   ============================================================ */
function CfPane() {
  return (
    <div className="mdpane">
      <h4>CF 优选加速</h4>
      <p className="hint">CF 优选 IP 测速 + 本地反代(改写线路走优选节点)。</p>
      <div className="empty" style={{ padding: "28px 0" }}>
        CF 优选测速与本地反代尚未在此端接入,待接。
      </div>
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
  const [busy, setBusy] = useState(false);
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
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function save() {
    if (busy) return;
    setBusy(true);
    try {
      const cfg: ProxyConfig = {
        type,
        host: host.trim(),
        port: Number(port) || 0,
        username: username.trim(),
        password,
        proxy_media: proxyMedia,
      };
      await setProxy(cfg);
      f.ok("代理已保存");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mdpane">
      <h4>代理设置</h4>
      <p className="hint">为元数据与登录请求走代理。选「直连」则不走代理。</p>
      <div className="fld">
        <label>代理类型</label>
        <Seg value={type} opts={PROXY_TYPES} onChange={setType} />
      </div>
      <div className="fld">
        <label>服务器</label>
        <div style={{ display: "flex", gap: 10 }}>
          <input
            className="field"
            placeholder="127.0.0.1"
            value={host}
            disabled={off}
            onChange={(e) => setHost(e.target.value)}
          />
          <input
            className="field"
            style={{ flex: "0 0 110px" }}
            placeholder="7890"
            inputMode="numeric"
            value={port}
            disabled={off}
            onChange={(e) => setPort(e.target.value.replace(/[^0-9]/g, ""))}
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
            disabled={off}
            onChange={(e) => setUsername(e.target.value)}
          />
          <input
            className="field"
            type="password"
            placeholder="密码"
            value={password}
            disabled={off}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
      </div>
      <Row t="播放流也走代理" d="开启后视频流量也经代理(可能拖慢直连)">
        <Sw on={proxyMedia} onChange={setProxyMedia} disabled={off} />
      </Row>
      <div className="st-actions">
        <button className="btn primary" disabled={busy} onClick={save}>
          {busy ? "保存中…" : "保存"}
        </button>
        {f.node}
      </div>
    </div>
  );
}

/* ============================================================
   同步 · 同步记录 · 跨服聚合 —— 无独立命令,诚实占位
   ============================================================ */
function SyncPane() {
  return (
    <div className="mdpane">
      <h4>同步记录 · 跨服聚合</h4>
      <p className="hint">跨服务器观看记录聚合与续播。</p>
      <div className="empty" style={{ padding: "28px 0" }}>
        跨服观看记录由核心自动聚合(取最大进度续播),此端暂无独立开关,待接。
      </div>
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
   ponytail: 直接 invoke plugin_* —— 本任务禁改 api.ts,故不走封装。
   ============================================================ */
type PluginInfo = {
  id: string;
  name: string;
  version: string;
  author?: string;
  enabled: boolean;
};
function PluginsPane() {
  const f = useFlash();
  const [list, setList] = useState<PluginInfo[] | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const load = () =>
    invoke<PluginInfo[]>("plugin_list")
      .then(setList)
      .catch((e) => {
        setList([]);
        f.err(e);
      });

  useEffect(() => {
    load();
  }, []);

  async function toggle(p: PluginInfo) {
    if (busy) return;
    setBusy(p.id);
    try {
      await invoke(p.enabled ? "plugin_disable" : "plugin_enable", { id: p.id });
      await load();
      f.ok(p.enabled ? "已停用" : "已启用");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="mdpane">
      <h4>插件</h4>
      <p className="hint">已安装插件的启用 / 停用。</p>
      {list == null ? (
        <div className="empty" style={{ padding: "28px 0" }}>
          <span className="spinner" />
        </div>
      ) : list.length === 0 ? (
        <div className="empty" style={{ padding: "28px 0" }}>
          还没有安装插件。
        </div>
      ) : (
        list.map((p) => (
          <Row key={p.id} t={p.name} d={`v${p.version}${p.author ? " · " + p.author : ""}`}>
            <Sw on={p.enabled} disabled={busy === p.id} onChange={() => toggle(p)} />
          </Row>
        ))
      )}
      {f.node}
    </div>
  );
}

/* ============================================================
   其它 · 更新 · 备份 · 关于
   ============================================================ */
function AboutPane() {
  const f = useFlash();
  const [payload, setPayload] = useState("");
  const [importText, setImportText] = useState("");
  const [busyOut, setBusyOut] = useState(false);
  const [busyIn, setBusyIn] = useState(false);

  async function doExport() {
    if (busyOut) return;
    setBusyOut(true);
    try {
      setPayload(await configExportQr());
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
      <p className="hint">在设备间搬运服务器配置(含凭据),以文本载荷复制粘贴。</p>
      <Row t="导出本机配置" d="生成 LPSYNC1 载荷,复制到另一台设备导入">
        <button className="btn" disabled={busyOut} onClick={doExport}>
          {busyOut ? "生成中…" : "导出"}
        </button>
      </Row>
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
