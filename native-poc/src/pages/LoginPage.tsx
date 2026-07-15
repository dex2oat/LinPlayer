import { useState } from "react";
import { type LoginResult, login } from "../lib/api";

export default function LoginPage({
  onLoggedIn,
}: {
  onLoggedIn: (s: LoginResult) => void;
}) {
  const [server, setServer] = useState("http://");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");

  async function submit() {
    if (busy) return;
    setErr("");
    setBusy(true);
    try {
      onLoggedIn(await login(server, username, password));
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="app-surface login-wrap">
      <div className="login-card enter">
        <div className="brand">
          Lin<span>Player</span>
        </div>
        <div className="brand-sub">Rust 核 · Tauri 壳 · 原生 mpv · 沉浸桌面</div>

        <label className="lbl">服务器地址</label>
        <input
          className="field"
          placeholder="http://ip:8096"
          value={server}
          onChange={(e) => setServer(e.target.value)}
        />
        <label className="lbl">用户名</label>
        <input
          className="field"
          placeholder="用户名"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
        />
        <label className="lbl">密码</label>
        <input
          className="field"
          type="password"
          placeholder="密码"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && submit()}
        />

        <button className="btn primary big" disabled={busy} onClick={submit}>
          {busy ? "登录中…" : "登录 Emby"}
        </button>
        {err && <div className="login-err">{err}</div>}
      </div>
    </div>
  );
}
