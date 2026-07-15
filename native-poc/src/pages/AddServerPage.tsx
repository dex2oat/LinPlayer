import { useState, type ReactNode } from "react";
import {
  configExportQr,
  configImportQr,
  login,
  sourceLogin,
} from "../lib/api";
import { IconCloud, IconFile, IconServer } from "../app/icons";
import "./AddServerPage.css";

/* ============================================================
   添加服务器页(桌面主从两栏,草稿 PAGE 6)。
   左 mdnav 选源类型,右 mdpane 就地出对应表单,取代移动端两次跳转。
   默认导出 AddServerPage。
   ============================================================ */

/** onDone(src):src 非空表示刚登录的是文件浏览型源,宿主该直接带去对应页。 */
type Props = { onDone: (src?: "netdisk" | "anirss") => void; onBack: () => void };

type TypeId =
  | "emby"
  | "openlist"
  | "quark"
  | "feiniu"
  | "anirss"
  | "batch"
  | "qrsync";

/* 扫码图标 icons 里没有,内联描边(currentColor,无 emoji)。 */
const IconQr = ({ size = 18 }: { size?: number }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.7}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden
  >
    <rect x="3" y="3" width="7" height="7" rx="1" />
    <rect x="14" y="3" width="7" height="7" rx="1" />
    <rect x="3" y="14" width="7" height="7" rx="1" />
    <path d="M14 14h3v3M20 14v.01M14 20h.01M17 20h.01M20 17v4" />
  </svg>
);

const NAV: { sec: string; items: { id: TypeId; label: string; icon: () => ReactNode }[] }[] = [
  {
    sec: "媒体服务器",
    items: [{ id: "emby", label: "Emby / Jellyfin", icon: () => <IconServer size={16} /> }],
  },
  {
    sec: "网盘 / 文件源",
    items: [
      { id: "openlist", label: "OpenList", icon: () => <IconCloud size={16} /> },
      { id: "quark", label: "夸克网盘", icon: () => <IconCloud size={16} /> },
      { id: "feiniu", label: "飞牛影视", icon: () => <IconCloud size={16} /> },
      { id: "anirss", label: "Ani-RSS", icon: () => <IconCloud size={16} /> },
    ],
  },
  {
    sec: "批量",
    items: [
      { id: "batch", label: "批量解析导入", icon: () => <IconFile size={16} /> },
      { id: "qrsync", label: "扫码搬配置", icon: () => <IconQr size={16} /> },
    ],
  },
];

export default function AddServerPage({ onDone, onBack }: Props) {
  const [sel, setSel] = useState<TypeId>("emby");

  // 各表单共用输入(切换类型时保留,填过的地址账号不用重敲)。
  const [server, setServer] = useState("https://");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [note, setNote] = useState(""); // ponytail: login() 无 note 参数,仅展示,核暂不落库
  const [cookie, setCookie] = useState("");
  const [batchText, setBatchText] = useState("");
  const [qrPayload, setQrPayload] = useState("");
  const [exportText, setExportText] = useState("");

  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [toast, setToast] = useState("");

  async function run(fn: () => Promise<void>) {
    if (busy) return;
    setErr("");
    setToast("");
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  // Emby/Jellyfin:navigate=false 仅测试连接(不跳走),true 添加后 onDone。
  const submitEmby = (navigate: boolean) =>
    run(async () => {
      await login(server, username, password);
      if (navigate) onDone();
      else setToast("连接成功");
    });

  const submitSource = (kind: "Openlist" | "Feiniu" | "Anirss") =>
    run(async () => {
      await sourceLogin(kind, server, username, password, null);
      onDone(kind === "Anirss" ? "anirss" : "netdisk");
    });

  const submitQuark = () =>
    run(async () => {
      await sourceLogin("Quark", "", "", "", cookie);
      onDone("netdisk");
    });

  const importQr = () =>
    run(async () => {
      const n = await configImportQr(qrPayload.trim());
      setToast(`已导入 ${n} 个账号`);
      window.setTimeout(onDone, 1000);
    });

  const exportQr = () =>
    run(async () => {
      setExportText(await configExportQr());
    });

  const spin = (label: string) =>
    busy ? <span className="spinner" /> : label;

  // 地址 + 用户名 + 密码(Emby 与网盘登录型共用)。
  const creds = (optional = false) => (
    <>
      <div className="fld">
        <label>服务器地址</label>
        <input
          className="field"
          placeholder="https://host:port"
          value={server}
          onChange={(e) => setServer(e.target.value)}
        />
      </div>
      <div className="as-grid2">
        <div className="fld">
          <label>用户名{optional ? "（可选）" : ""}</label>
          <input
            className="field"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </div>
        <div className="fld">
          <label>密码{optional ? "（可选）" : ""}</label>
          <input
            className="field"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
      </div>
    </>
  );

  function pane() {
    switch (sel) {
      case "emby":
        return (
          <>
            <h4>Emby / Jellyfin</h4>
            <p className="hint">填写服务器地址与账号，测试连接后添加。</p>
            {creds()}
            <div className="fld">
              <label>备注（可选）</label>
              <input
                className="field"
                placeholder="家里的 Emby"
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button className="pill" disabled={busy} onClick={() => submitEmby(false)}>
                {spin("测试连接")}
              </button>
              <button
                className="btn primary"
                disabled={busy}
                onClick={() => submitEmby(true)}
              >
                {spin("添加")}
              </button>
            </div>
          </>
        );

      case "openlist":
      case "feiniu":
      case "anirss": {
        const meta = {
          openlist: { title: "OpenList", kind: "Openlist" as const, optional: false },
          feiniu: { title: "飞牛影视", kind: "Feiniu" as const, optional: false },
          anirss: { title: "Ani-RSS", kind: "Anirss" as const, optional: true },
        }[sel];
        return (
          <>
            <h4>{meta.title}</h4>
            <p className="hint">填写服务器地址与账号后添加。</p>
            {creds(meta.optional)}
            <div className="as-actions">
              <button
                className="btn primary"
                disabled={busy}
                onClick={() => submitSource(meta.kind)}
              >
                {spin("添加")}
              </button>
            </div>
          </>
        );
      }

      case "quark":
        return (
          <>
            <h4>夸克网盘</h4>
            <p className="hint">夸克使用 Cookie 登录。</p>
            <p className="as-warn">扫码待接，先用 Cookie：浏览器登录夸克后复制整段 Cookie 粘贴到下方。</p>
            <div className="fld">
              <label>Cookie</label>
              <textarea
                className="field"
                rows={5}
                placeholder="__pus=…; __kp=…; …"
                value={cookie}
                onChange={(e) => setCookie(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button className="btn primary" disabled={busy} onClick={submitQuark}>
                {spin("添加")}
              </button>
            </div>
          </>
        );

      case "batch":
        return (
          <>
            <h4>批量解析导入</h4>
            <p className="hint">一行一个服务器,批量解析并添加。</p>
            <p className="as-warn">待接批量引擎（核心暂无对应命令，此处为占位不会真正导入）。</p>
            <div className="fld">
              <label>服务器列表</label>
              <textarea
                className="field"
                rows={7}
                placeholder={"https://a.lan:8096 user pass\nhttps://b.lan:8096 user pass"}
                value={batchText}
                onChange={(e) => setBatchText(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button className="btn primary" disabled title="待接批量引擎">
                添加
              </button>
            </div>
          </>
        );

      case "qrsync":
        return (
          <>
            <h4>扫码搬配置</h4>
            <p className="hint">在另一台设备导出配置,把 LPSYNC1 载荷粘到这里导入(离线直传凭据)。</p>
            <p className="as-warn">无内置二维码库,此处用文本载荷收发(诚实占位)。</p>
            <div className="fld">
              <label>导入载荷</label>
              <textarea
                className="field"
                rows={4}
                placeholder="LPSYNC1:…"
                value={qrPayload}
                onChange={(e) => setQrPayload(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button
                className="btn primary"
                disabled={busy || !qrPayload.trim()}
                onClick={importQr}
              >
                {spin("导入")}
              </button>
              <button className="pill" disabled={busy} onClick={exportQr}>
                {spin("导出本机配置")}
              </button>
            </div>
            {exportText && (
              <div className="fld" style={{ marginTop: 14 }}>
                <label>本机配置载荷（复制到另一台设备导入）</label>
                <textarea className="field" rows={4} readOnly value={exportText} />
              </div>
            )}
          </>
        );
    }
  }

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <button className="crumb-btn" onClick={onBack}>
            服务器
          </button>{" "}
          › <b>添加</b>
        </span>
      </div>

      <div className="scroll">
        {/* 包一层 .cbody(和设置页同构):由 .cbody 统一封顶居中 + 给出 18px 水槽,
            否则 .md 直接坐在 .scroll 里会贴死窗口边、且超宽屏下拉成一条线。 */}
        <div className="cbody">
          <div className="md">
            <div className="mdnav">
              {NAV.map((g) => (
                <div key={g.sec}>
                  <div className="sec">{g.sec}</div>
                  {g.items.map((it) => (
                    <button
                      key={it.id}
                      className={`it${sel === it.id ? " on" : ""}`}
                      onClick={() => {
                        setSel(it.id);
                        setErr("");
                        setToast("");
                      }}
                    >
                      {it.icon()}
                      {it.label}
                    </button>
                  ))}
                </div>
              ))}
            </div>
            <div className="mdpane">{pane()}</div>
          </div>
        </div>
        <div style={{ height: 40 }} />
      </div>

      {err && <div className="toast error">{err}</div>}
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
