import { useState } from "react";
import { login } from "@shared/api";
import { Icon } from "../app/icons";
import CompanionQr from "../components/CompanionQr";
import { FocusColumn, FocusInput, FocusItem } from "../components/Focus";

/** 首次启动 / 添加服务器。

    ★ **主路径是扫码,不是打字。** 电视没摄像头,所以方向只能是「电视出码、手机扫」:
      核层在局域网起一个小网页(crates/core/src/companion.rs),右边那张码就是它的地址。
      手机上填完提交,核层直接登录并广播 `lp://accounts-changed`,这一屏自己就换走了 ——
      **这里不用轮询,也不用自己跳页**(轮询版是上一稿,已删)。
      而且手机上那一页不只是登录表单:遥控、搜片、改设置、加更多服务器都在上面。

    ★ 手填表单是退路(没手机 / 扫不出来),但它也不再是「选中框 → 按确认进输入态 →
      按返回退出」两段式:焦点框**就是**输入框,上下键随时换字段,先填哪个由用户定。
      理由和实现都在 Focus.tsx 的 FocusInput 上。

    ★ 不自建虚拟键盘 —— Android TV 有系统输入法(Leanback IME),还白拿语音输入和外接键盘。
      但**系统键盘会盖住下半屏**,所以输入的东西全排在上半屏(y < 540dp)。 */
export default function OnboardingPage({ onDone }: { onDone?: () => void } = {}) {
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
      /* 首次启动不用自己跳页:login 会广播 ACCOUNTS_CHANGED,
         App 重问 current_session 拿到会话,自然换到首页。
         但**已有会话时**(从服务器页进来加第二台)那条广播不会换页 ——
         此时靠 onDone 退回服务器页,否则加完就卡在这张表单上。 */
      onDone?.();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={{ display: "flex", gap: 56, height: "100%" }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <FocusColumn focusKey="ONBOARD">
          <div style={{ padding: "56px 0 0 64px", maxWidth: 820 }}>
            <div className="ptitle">添加服务器</div>
            <div className="psub">
              推荐用右边的二维码在手机上填 —— 遥控器打字太累。上下键换输入框。
            </div>

            <Field
              label="服务器地址"
              value={server}
              onChange={setServer}
              placeholder="https://"
              inputMode="url"
            />
            <Field label="用户名" value={user} onChange={setUser} />
            <Field label="密码" value={pass} onChange={setPass} password />

            {err && (
              <div style={{ color: "var(--danger)", fontSize: 19, marginBottom: 20 }}>{err}</div>
            )}

            <div className="btnrow">
              {/* ★ 初始焦点停在按钮上,**不停在输入框上**:焦点落到输入框会立刻拉起
                  系统输入法盖住半屏,而这一页的主路径是扫码 —— 一进来就被键盘糊住
                  就等于把主路径挡了。要打字的人按一下↑就进第一个框,键盘那时才升起。 */}
              <FocusItem className="btn pri fx" autoFocus onEnter={submit}>
                <Icon n="check" className="ic ic-btn" />
                {busy ? "连接中…" : "连接"}
              </FocusItem>
            </div>
          </div>
        </FocusColumn>
      </div>

      <div style={{ width: 560, flex: "none", padding: "56px 64px 0 0" }}>
        <CompanionQr
          title="手机扫码填写"
          hint="手机和电视连同一个 Wi-Fi,扫码后在手机上填好提交,电视这边自动登录。之后这一页还能当遥控器用。"
        />
      </div>
    </div>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
  password,
  inputMode,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  password?: boolean;
  inputMode?: "text" | "url" | "numeric";
}) {
  return (
    <div className="field">
      <div className="lb">{label}</div>
      <FocusInput
        className="in"
        value={value}
        onChange={onChange}
        placeholder={placeholder}
        password={password}
        inputMode={inputMode}
      />
    </div>
  );
}
