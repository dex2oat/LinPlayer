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
type SourceEntry = { id: string; name: string; is_dir: boolean; is_video: boolean; size: number | null; thumb_url: string | null; raw?: unknown };
type ServerGroup = { server_id: string; server_name: string; items: Item[] };

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

  // 聚合搜索(跨所有已登录 Emby 服务器)+ 多账号
  const [addingServer, setAddingServer] = useState(false);
  const [searchQuery, setSearchQuery] = useState("");
  const [searchGroups, setSearchGroups] = useState<ServerGroup[] | null>(null);

  // 文件浏览型源(网盘)
  const [loginTab, setLoginTab] = useState<"emby" | "source">("emby");
  const [srcKind, setSrcKind] = useState("openlist");
  const [cookieText, setCookieText] = useState("");
  const [source, setSource] = useState<{ kind: string } | null>(null);
  const [srcItems, setSrcItems] = useState<SourceEntry[]>([]);
  const [srcCrumbs, setSrcCrumbs] = useState<Crumb[]>([]);

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
      setSession(r); setAddingServer(false);
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

  // ---------- 聚合搜索(跨服)----------
  async function doAggSearch() {
    const q = searchQuery.trim();
    if (!q) { setSearchGroups(null); return; }
    setBusy(true); setErr("");
    try { setSearchGroups(await invoke<ServerGroup[]>("aggregate_search", { query: q })); }
    catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function playAgg(g: ServerGroup, it: Item) {
    setErr("");
    try {
      await invoke("set_active_server", { serverId: g.server_id }); // 切到该条目所在服
      await playItem(it);
    } catch (e) { setErr(String(e)); }
  }

  // ---------- 网盘源 ----------
  async function doSourceLogin() {
    setErr(""); setBusy(true);
    try {
      await invoke("source_login", {
        kind: srcKind, baseUrl: server, username, password,
        cookie: srcKind === "quark" ? cookieText : null,
      });
      setSource({ kind: srcKind });
      setSrcItems(await invoke<SourceEntry[]>("source_list_dir", { dirId: null }));
      setSrcCrumbs([]);
    } catch (e) { setErr(String(e)); }
    finally { setBusy(false); }
  }

  async function openSrcDir(e: SourceEntry) {
    setBusy(true); setErr("");
    try {
      setSrcItems(await invoke<SourceEntry[]>("source_list_dir", { dirId: e.id }));
      setSrcCrumbs((c) => [...c, { id: e.id, name: e.name }]);
    } catch (er) { setErr(String(er)); }
    finally { setBusy(false); }
  }

  async function gotoSrcCrumb(idx: number) {
    setBusy(true);
    try {
      const dirId = idx < 0 ? null : srcCrumbs[idx].id;
      setSrcItems(await invoke<SourceEntry[]>("source_list_dir", { dirId }));
      setSrcCrumbs(idx < 0 ? [] : srcCrumbs.slice(0, idx + 1));
    } catch (er) { setErr(String(er)); }
    finally { setBusy(false); }
  }

  async function playSrc(e: SourceEntry) {
    setErr("");
    try {
      const resume = await invoke<number>("source_play", { entryId: e.id, entryName: e.name, resumeSecs: 0, raw: e.raw ?? null });
      setPlaying({ id: e.id, name: e.name, type_: "", is_folder: false, has_primary: false, runtime_secs: 0, resume_secs: 0 });
      setStatus({ time: resume, duration: 0, paused: false, buffered: 0 });
      setTimeout(async () => {
        try { await invoke("apply_prefs"); } catch {}
        setTracks(await invoke<Track[]>("tracks"));
      }, 1200);
    } catch (er) { setErr(String(er)); }
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
        // 302 看门狗:网盘直链失效时自动重签续播(对 Emby 无副作用)
        invoke("source_watchdog", { pos: st.time }).catch(() => {});
      } catch {}
    }, 500);
    return () => { if (timer.current) window.clearInterval(timer.current); };
  }, [playing]);

  const posterUrl = (it: Item) =>
    session && it.has_primary
      ? `${session.server}/Items/${it.id}/Images/Primary?maxHeight=360&api_key=${session.token}`
      : "";

  // ---------- 登录页 ----------
  if ((!session && !source) || addingServer) {
    const isSrc = loginTab === "source";
    return (
      <div className="screen login">
        <div className="login-card">
          <div className="brand">LinPlayer <span>PoC</span></div>
          <div className="sub">Rust 核 · Tauri 壳 · 原生 mpv</div>
          <div className="tabs">
            <button className={!isSrc ? "on" : ""} onClick={() => setLoginTab("emby")}>Emby</button>
            <button className={isSrc ? "on" : ""} onClick={() => setLoginTab("source")}>网盘</button>
          </div>
          {isSrc && (
            <select value={srcKind} onChange={(e) => setSrcKind(e.target.value)}>
              <option value="openlist">OpenList / AList</option>
              <option value="anirss">Ani-rss</option>
              <option value="feiniu">飞牛影视</option>
              <option value="quark">夸克网盘(Cookie)</option>
            </select>
          )}
          {isSrc && srcKind === "quark" ? (
            <textarea className="cookie-box" placeholder="粘贴夸克 Cookie（含 __puus）"
                      value={cookieText} onChange={(e) => setCookieText(e.target.value)} />
          ) : (
            <>
              <input placeholder={isSrc ? "服务器地址 http://ip:5244" : "服务器地址 http://ip:8096"}
                     value={server} onChange={(e) => setServer(e.target.value)} />
              <input placeholder="用户名" value={username} onChange={(e) => setUsername(e.target.value)} />
              <input placeholder="密码" type="password" value={password} onChange={(e) => setPassword(e.target.value)}
                     onKeyDown={(e) => e.key === "Enter" && (isSrc ? doSourceLogin() : doLogin())} />
            </>
          )}
          <button disabled={busy} onClick={isSrc ? doSourceLogin : doLogin}>
            {busy ? "登录中…" : isSrc ? "连接网盘" : "登录 Emby"}
          </button>
          {addingServer && (
            <button className="ghost" onClick={() => setAddingServer(false)}>取消</button>
          )}
          {err && <div className="err">{err}</div>}
        </div>
      </div>
    );
  }

  // ---------- 浏览页 ----------
  const audio = tracks.filter((t) => t.kind === "audio");
  const subs = tracks.filter((t) => t.kind === "sub");

  // 播放层(透明,露出底下 mpv)—— Emby 与网盘源共用
  const playerLayer = playing && (
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
  );

  // 网盘源浏览页
  if (source) {
    return (
      <div className={`screen${playing ? " playing" : ""}`}>
        <div className="topbar">
          <div className="crumbs">
            <span onClick={() => gotoSrcCrumb(-1)}>网盘根目录</span>
            {srcCrumbs.map((c, i) => (
              <span key={c.id + i}> / <b onClick={() => gotoSrcCrumb(i)}>{c.name}</b></span>
            ))}
          </div>
          {busy && <div className="spinner" />}
        </div>
        <div className="grid">
          {srcItems.map((e) => (
            <div key={e.id} className="card"
                 onClick={() => (e.is_dir ? openSrcDir(e) : e.is_video ? playSrc(e) : undefined)}>
              <div className="poster">
                {e.thumb_url
                  ? <img src={e.thumb_url} onError={(ev) => ((ev.target as HTMLImageElement).style.display = "none")} />
                  : <div className="poster-fallback">{e.is_dir ? "📁" : e.is_video ? "🎬" : "📄"}</div>}
              </div>
              <div className="cap" title={e.name}>{e.name}</div>
            </div>
          ))}
          {!srcItems.length && !busy && <div className="empty">这里没有内容</div>}
        </div>
        {err && <div className="toast">{err}</div>}
        {playerLayer}
      </div>
    );
  }

  // Emby 浏览页
  return (
    <div className={`screen${playing ? " playing" : ""}`}>
      <div className="topbar">
        <div className="crumbs">
          <span onClick={() => { setSearchGroups(null); gotoCrumb(-1); }}>{session?.user_name} 的媒体库</span>
          {!searchGroups && crumbs.map((c, i) => (
            <span key={c.id}> / <b onClick={() => gotoCrumb(i)}>{c.name}</b></span>
          ))}
          {searchGroups && <span> / 搜索「{searchQuery}」</span>}
        </div>
        <input className="searchbox" placeholder="跨服搜索…" value={searchQuery}
               onChange={(e) => setSearchQuery(e.target.value)}
               onKeyDown={(e) => e.key === "Enter" && doAggSearch()} />
        <button className="ghost" onClick={() => setAddingServer(true)}>＋服务器</button>
        {busy && <div className="spinner" />}
      </div>

      {searchGroups ? (
        <div className="agg-wrap">
          {!searchGroups.length && !busy && <div className="empty">没有找到结果</div>}
          {searchGroups.map((g) => (
            <div key={g.server_id} className="agg-group">
              <div className="agg-server">{g.server_name} · {g.items.length}</div>
              <div className="grid">
                {g.items.map((it) => (
                  <div key={g.server_id + it.id} className="card" onClick={() => playAgg(g, it)}>
                    <div className="poster">
                      <div className="poster-fallback">{it.type_ === "Series" ? "📺" : "🎬"}</div>
                    </div>
                    <div className="cap" title={it.name}>{it.name}</div>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>
      ) : (
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
      )}

      {err && <div className="toast">{err}</div>}
      {playerLayer}
    </div>
  );
}
