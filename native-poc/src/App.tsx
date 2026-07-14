import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import "./styles.css";

type LoginResult = { server: string; token: string; user_id: string; user_name: string };
type Item = {
  id: string;
  name: string;
  type_: string;
  is_folder: boolean;
  has_primary: boolean;
  runtime_secs: number;
  resume_secs: number;
};
type Status = { time: number; duration: number; paused: boolean; buffered: number };
type Track = { kind: string; id: string; title: string; lang: string; selected: boolean };
type Prefs = { audio_lang: string | null; sub_lang: string | null; sub_enabled: boolean };
type Crumb = { id: string; name: string };

function fmt(t: number) {
  if (!isFinite(t) || t < 0) t = 0;
  const s = Math.floor(t % 60).toString().padStart(2, "0");
  const m = Math.floor((t / 60) % 60).toString().padStart(2, "0");
  const h = Math.floor(t / 3600);
  return h > 0 ? `${h}:${m}:${s}` : `${m}:${s}`;
}

export default function App() {
  const [session, setSession] = useState<LoginResult | null>(null);
  const [server, setServer] = useState("http://");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  const [crumbs, setCrumbs] = useState<Crumb[]>([]);
  const [items, setItems] = useState<Item[]>([]);

  const [playing, setPlaying] = useState<Item | null>(null);
  const [status, setStatus] = useState<Status>({ time: 0, duration: 0, paused: false, buffered: 0 });
  const [tracks, setTracks] = useState<Track[]>([]);
  const [prefs, setPrefs] = useState<Prefs>({ audio_lang: null, sub_lang: null, sub_enabled: true });
  const [seeking, setSeeking] = useState<number | null>(null);
  const timer = useRef<number | null>(null);
  const tick = useRef(0);

  // 载入已存播放偏好
  useEffect(() => { invoke<Prefs>("get_prefs").then(setPrefs).catch(() => {}); }, []);

  const trackLang = (list: Track[], id: string) => list.find((t) => t.id === id)?.lang || "";
  async function persistPrefs(next: Prefs) {
    setPrefs(next);
    await invoke("set_prefs", {
      audioLang: next.audio_lang, subLang: next.sub_lang, subEnabled: next.sub_enabled,
    }).catch(() => {});
  }

  // 启动时:若有已存账号,跳过登录页直接进库(重启免登)
  useEffect(() => {
    (async () => {
      const s = await invoke<LoginResult | null>("current_session");
      if (!s) return;
      setSession(s);
      try { setItems(await invoke<Item[]>("views")); setCrumbs([]); }
      catch (e) { setErr(String(e)); }
    })();
  }, []);

  async function doLogin() {
    setErr(""); setBusy(true);
    try {
      const r = await invoke<LoginResult>("login", { server, username, password });
      setSession(r);
      const v = await invoke<Item[]>("views");
      setItems(v); setCrumbs([]);
    } catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function openFolder(it: Item) {
    setBusy(true); setErr("");
    try {
      const list = await invoke<Item[]>("list_items", { parentId: it.id });
      setItems(list); setCrumbs((c) => [...c, { id: it.id, name: it.name }]);
    } catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function gotoCrumb(idx: number) {
    setBusy(true);
    try {
      if (idx < 0) { setItems(await invoke<Item[]>("views")); setCrumbs([]); }
      else {
        const c = crumbs[idx];
        setItems(await invoke<Item[]>("list_items", { parentId: c.id }));
        setCrumbs(crumbs.slice(0, idx + 1));
      }
    } catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function playItem(it: Item) {
    setErr("");
    try {
      // 从上次进度续播;返回实际起播秒数,进度条直接定位
      const resume = await invoke<number>("play", { itemId: it.id, resumeSecs: it.resume_secs });
      setPlaying(it);
      setStatus({ time: resume, duration: it.runtime_secs, paused: false, buffered: 0 });
      setTimeout(async () => {
        try { await invoke("apply_prefs"); } catch {}           // 按语言偏好自动选轨
        setTracks(await invoke<Track[]>("tracks"));
      }, 1200);
    } catch (e) { setErr(String(e)); }
  }

  async function togglePause() {
    const p = !status.paused;
    await invoke("set_pause", { paused: p });
    setStatus((s) => ({ ...s, paused: p }));
    invoke("report_progress", { pos: status.time, paused: p }).catch(() => {});
  }

  async function closePlayer() {
    // 上报 stopped 写回最终进度(续播落地),再退出播放层
    await invoke("stop_playback", { pos: status.time }).catch(() => {});
    setPlaying(null); setTracks([]);
  }

  // 播放中轮询状态 + 每 ~5s 上报一次进度(存活于崩溃/直接关窗)
  useEffect(() => {
    if (!playing) { if (timer.current) window.clearInterval(timer.current); return; }
    tick.current = 0;
    timer.current = window.setInterval(async () => {
      try {
        const st = await invoke<Status>("status");
        setStatus(st);
        tick.current++;
        if (tick.current % 10 === 0) {
          invoke("report_progress", { pos: st.time, paused: st.paused }).catch(() => {});
        }
      } catch {}
    }, 500);
    return () => { if (timer.current) window.clearInterval(timer.current); };
  }, [playing]);

  const posterUrl = (it: Item) =>
    session && it.has_primary
      ? `${session.server}/Items/${it.id}/Images/Primary?maxHeight=360&api_key=${session.token}`
      : "";

  // ---------- 登录页 ----------
  if (!session) {
    return (
      <div className="screen login">
        <div className="login-card">
          <div className="brand">LinPlayer <span>PoC</span></div>
          <div className="sub">Rust 核 · Tauri 壳 · 原生 mpv</div>
          <input placeholder="服务器地址 http://ip:8096" value={server} onChange={(e) => setServer(e.target.value)} />
          <input placeholder="用户名" value={username} onChange={(e) => setUsername(e.target.value)} />
          <input placeholder="密码" type="password" value={password} onChange={(e) => setPassword(e.target.value)}
                 onKeyDown={(e) => e.key === "Enter" && doLogin()} />
          <button disabled={busy} onClick={doLogin}>{busy ? "登录中…" : "登录 Emby"}</button>
          {err && <div className="err">{err}</div>}
        </div>
      </div>
    );
  }

  // ---------- 浏览页 ----------
  const audio = tracks.filter((t) => t.kind === "audio");
  const subs = tracks.filter((t) => t.kind === "sub");

  return (
    <div className={`screen${playing ? " playing" : ""}`}>
      <div className="topbar">
        <div className="crumbs">
          <span onClick={() => gotoCrumb(-1)}>{session.user_name} 的媒体库</span>
          {crumbs.map((c, i) => (
            <span key={c.id}> / <b onClick={() => gotoCrumb(i)}>{c.name}</b></span>
          ))}
        </div>
        {busy && <div className="spinner" />}
      </div>

      <div className="grid">
        {items.map((it) => (
          <div key={it.id} className="card" onClick={() => (it.is_folder ? openFolder(it) : playItem(it))}>
            <div className="poster">
              {posterUrl(it)
                ? <img src={posterUrl(it)} onError={(e) => ((e.target as HTMLImageElement).style.display = "none")} />
                : <div className="poster-fallback">{it.is_folder ? "📁" : "🎬"}</div>}
              {!it.is_folder && it.resume_secs > 0 && it.runtime_secs > 0 && (
                <div className="resume" style={{ width: `${Math.min(100, (it.resume_secs / it.runtime_secs) * 100)}%` }} />
              )}
            </div>
            <div className="cap" title={it.name}>{it.name}</div>
          </div>
        ))}
        {!items.length && !busy && <div className="empty">这里没有内容</div>}
      </div>

      {err && <div className="toast">{err}</div>}

      {/* ---------- 播放层(透明,露出底下 mpv)---------- */}
      {playing && (
        <div className="player-layer">
          <div className="p-top">
            <span className="p-title">{playing.name}</span>
            <button className="p-close" onClick={closePlayer}>✕</button>
          </div>

          <div className="p-controls">
            <button className="p-play" onClick={togglePause}>{status.paused ? "▶" : "⏸"}</button>
            <span className="p-time">{fmt(seeking ?? status.time)}</span>
            <input
              className="p-seek" type="range" min={0} max={Math.max(1, status.duration)} step={0.5}
              value={seeking ?? status.time}
              onChange={(e) => setSeeking(Number(e.target.value))}
              onMouseUp={async () => { if (seeking != null) { await invoke("seek", { pos: seeking }); setSeeking(null); } }}
            />
            <span className="p-time">{fmt(status.duration)}</span>

            {audio.length > 1 && (
              <select onChange={(e) => {
                        const id = e.target.value;
                        invoke("set_track", { kind: "audio", id });
                        persistPrefs({ ...prefs, audio_lang: trackLang(audio, id) || prefs.audio_lang });
                      }}
                      defaultValue={audio.find((t) => t.selected)?.id}>
                {audio.map((t) => <option key={t.id} value={t.id}>音轨 {t.id} {t.lang || t.title}</option>)}
              </select>
            )}
            <select onChange={(e) => {
                      const id = e.target.value;
                      invoke("set_track", { kind: "sub", id });
                      if (id === "no") persistPrefs({ ...prefs, sub_enabled: false });
                      else persistPrefs({ ...prefs, sub_enabled: true, sub_lang: trackLang(subs, id) || prefs.sub_lang });
                    }}
                    defaultValue={subs.find((t) => t.selected)?.id ?? "no"}>
              <option value="no">字幕关</option>
              {subs.map((t) => <option key={t.id} value={t.id}>字幕 {t.id} {t.lang || t.title}</option>)}
            </select>
          </div>
        </div>
      )}
    </div>
  );
}
