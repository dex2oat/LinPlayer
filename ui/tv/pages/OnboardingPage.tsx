import { useState } from "react";
import { login } from "@shared/api";
import { Icon } from "../app/icons";
import { FocusColumn, FocusItem } from "../components/Focus";

/** 首次启动:加一台 Emby 服务器。

    ★ 不自建虚拟键盘 —— Android TV 有系统输入法(Leanback IME),输入框聚焦按确认即升起,
      还白拿语音输入和外接键盘。自建只会更难用,还得自己维护中文候选。
    ★ 但**系统键盘会盖住下半屏**,所以三个输入框都排在上半屏(y < 540dp)。 */
export default function OnboardingPage() {
  const [server, setServer] = useState("");
  const [user, setUser] = useState("");
  const [pass, setPass] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const submit = async () => {
    if (!server.trim() || busy) return;
    setBusy(true);
    setErr(null);
    try {
      await login(server.trim(), user.trim(), pass);
      /* 成功后不用自己跳页:login 会广播 ACCOUNTS_CHANGED,
         App 重问 current_session 拿到会话,自然换到首页。 */
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <FocusColumn focusKey="ONBOARD">
      <div style={{ padding: "56px 64px 0", maxWidth: 900 }}>
        <div className="ptitle">添加服务器</div>
        <div className="psub">填写 Emby 地址与账号。</div>

        <Field label="服务器地址" value={server} onChange={setServer} placeholder="https://" autoFocus />
        <Field label="用户名" value={user} onChange={setUser} />
        <Field label="密码" value={pass} onChange={setPass} password />

        {err && (
          <div style={{ color: "var(--danger)", fontSize: 19, marginBottom: 20 }}>{err}</div>
        )}

        <div className="btnrow">
          <FocusItem className="btn pri fx" onEnter={submit}>
            <Icon n="check" className="ic ic-btn" />
            {busy ? "连接中…" : "连接"}
          </FocusItem>
        </div>
      </div>
    </FocusColumn>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  password,
  autoFocus,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  password?: boolean;
  autoFocus?: boolean;
}) {
  return (
    <div className="field">
      <div className="lb">{label}</div>
      {/* FocusItem 包一层是为了进焦点树;真正接收输入的是里面的原生 input。
          shouldFocusDOMNode:true 让库同时调 DOM focus() → 系统输入法才会升起。 */}
      <FocusItem className="fx" autoFocus={autoFocus}>
        <input
          className="in"
          type={password ? "password" : "text"}
          value={value}
          placeholder={placeholder}
          onChange={(e) => onChange(e.target.value)}
        />
      </FocusItem>
    </div>
  );
}
