import { useCallback, useEffect, useMemo, useState } from "react";
import {
  type AccountInfo,
  type LoginResult,
  listAccounts,
  login,
  removeAccount,
  setActiveServer,
} from "../lib/api";
import { IconClose, IconPlus, IconRefresh, IconServer } from "../app/icons";
import "./ServersPage.css";

/* props 严格签名 —— session 由外层透传(预留给线路探测等后续能力),本页暂不消费。 */
type Props = {
  session: LoginResult;
  activeServer: string;
  onChanged: () => void;
  onGoAdd: () => void;
};

/* ---------- 本机侧元数据(备注/图标) —— 核无持久化命令,存 localStorage,诚实即可 ---------- */
type Meta = { remark?: string; icon?: string };
const metaKey = (server: string) => `sv:meta:${server}`;
function getMeta(server: string): Meta {
  try {
    return JSON.parse(localStorage.getItem(metaKey(server)) || "{}");
  } catch {
    return {};
  }
}
function setMeta(server: string, patch: Meta) {
  localStorage.setItem(metaKey(server), JSON.stringify({ ...getMeta(server), ...patch }));
}

/* 内置图标集(几何字形,非 emoji,对齐草稿 .iconpick)。空串 = 恢复默认 IconServer。 */
const GLYPHS = [
  "▣", "☁", "▦", "◆", "★", "♪", "▶", "⌘", "◈", "⬡",
  "✦", "◐", "❄", "▲", "◍", "✚", "❖", "⬟", "◑", "⬢",
];

/** 卡片/弹窗内统一的图标渲染:URL/DataURL→图片,字形→文本,否则默认服务器图标。 */
function ServerGlyph({ icon, size = 20 }: { icon?: string; size?: number }) {
  if (icon && (icon.startsWith("http") || icon.startsWith("data:")))
    return <img className="sv-sic-img" src={icon} alt="" />;
  if (icon) return <span className="sv-glyph" style={{ fontSize: size }}>{icon}</span>;
  return <IconServer size={size} />;
}

/** 视图切换用的内联图标(icons.tsx 无网格/列表图标,就地描边,不用 emoji)。 */
function IconView({ mode, size = 15 }: { mode: "grid" | "list"; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {mode === "grid" ? (
        <><rect x="3" y="3" width="8" height="8" rx="1.4" /><rect x="13" y="3" width="8" height="8" rx="1.4" />
          <rect x="3" y="13" width="8" height="8" rx="1.4" /><rect x="13" y="13" width="8" height="8" rx="1.4" /></>
      ) : (
        <><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01" /></>
      )}
    </svg>
  );
}

type DlgKind = "edit" | "relogin" | "lines" | "icon" | "remark" | "delete";

export default function ServersPage({ activeServer, onChanged, onGoAdd }: Props) {
  const [accounts, setAccounts] = useState<AccountInfo[] | null>(null);
  const [err, setErr] = useState("");
  const [q, setQ] = useState("");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [pending, setPending] = useState(""); // 正在切换的 server(单飞)
  const [metaVer, setMetaVer] = useState(0); // 本机元数据变更计数,驱动重渲染
  const [menu, setMenu] = useState<{ srv: AccountInfo; x: number; y: number } | null>(null);
  const [dlg, setDlg] = useState<{ kind: DlgKind; srv: AccountInfo } | null>(null);

  const reload = useCallback(async () => {
    try {
      setAccounts(await listAccounts());
    } catch (e) {
      setErr(String(e));
      setAccounts([]);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  // 右键菜单:点击别处 / Esc 关闭。
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setMenu(null);
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [menu]);

  const isActive = (a: AccountInfo) => a.active || a.server === activeServer;

  const shown = useMemo(() => {
    const list = accounts ?? [];
    const kw = q.trim().toLowerCase();
    if (!kw) return list;
    return list.filter(
      (a) =>
        a.user_name.toLowerCase().includes(kw) ||
        (getMeta(a.server).remark || "").toLowerCase().includes(kw),
    );
    // metaVer:备注变化时重算过滤。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accounts, q, metaVer]);

  async function doSwitch(a: AccountInfo) {
    if (pending || isActive(a)) return;
    setErr("");
    setPending(a.server);
    try {
      await setActiveServer(a.server);
      onChanged();
      await reload();
    } catch (e) {
      setErr(String(e));
    } finally {
      setPending("");
    }
  }

  const openMenu = (e: React.MouseEvent, srv: AccountInfo) => {
    e.preventDefault();
    e.stopPropagation();
    setMenu({ srv, x: Math.min(e.clientX, window.innerWidth - 192), y: Math.min(e.clientY, window.innerHeight - 260) });
  };

  // 弹窗收尾:sessionChanged 时通知外层刷新会话;总是重拉账号 + 关窗。
  const finish = useCallback(
    async (sessionChanged: boolean) => {
      if (sessionChanged) onChanged();
      await reload();
      setMetaVer((v) => v + 1);
      setDlg(null);
    },
    [onChanged, reload],
  );
  const applyLocal = useCallback(() => {
    setMetaVer((v) => v + 1);
    setDlg(null);
  }, []);

  const count = accounts?.length ?? 0;

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>服务器</b> <span className="count">· {count}</span>
        </span>
        <span className="push">
          <label className="searchbox">
            <IconServer size={14} />
            <input
              className="sv-search-inp"
              placeholder="搜索服务器…"
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
          </label>
          <button
            className={`ibtn${view === "list" ? " on" : ""}`}
            title={view === "grid" ? "切换列表视图" : "切换网格视图"}
            onClick={() => setView((v) => (v === "grid" ? "list" : "grid"))}
          >
            <IconView mode={view === "grid" ? "list" : "grid"} />
          </button>
          <button className="btn primary sm" onClick={onGoAdd}>
            <IconPlus size={15} /> 添加服务器
          </button>
        </span>
      </div>

      <div className="scroll">
        {err && (
          <div className="toast error" onClick={() => setErr("")}>
            {err}
          </div>
        )}

        {accounts == null ? (
          <div className="empty">
            <span className="spinner" />
          </div>
        ) : accounts.length === 0 ? (
          <div className="empty">还没有服务器,点右上角「添加服务器」。</div>
        ) : shown.length === 0 ? (
          <div className="empty">没有匹配「{q}」的服务器。</div>
        ) : (
          <div className={`sv-srvgrid${view === "list" ? " list" : ""}`}>
            {shown.map((a, i) => {
              const active = isActive(a);
              const meta = getMeta(a.server);
              const busy = pending === a.server;
              return (
                <div
                  key={a.server}
                  className={`sv-srvcard enter${active ? " cur" : ""}`}
                  style={{ animationDelay: `${Math.min(i, 12) * 26}ms` }}
                  onClick={() => doSwitch(a)}
                  onContextMenu={(e) => openMenu(e, a)}
                  title={active ? "当前服务器" : "点击切换到此服务器"}
                >
                  <span className="sv-sic">
                    {busy ? <span className="spinner" /> : <ServerGlyph icon={meta.icon} />}
                  </span>
                  <div className="sv-col">
                    <span className="sv-nm">
                      <span className={`dot ${active ? "on" : "none"}`} />
                      {a.user_name}
                    </span>
                    <span className="sv-rm">{meta.remark || "无备注"}</span>
                  </div>
                  <span className="sv-type">Emby</span>
                  {active && <span className="sv-cur-tag">当前</span>}
                </div>
              );
            })}
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>

      {menu && (
        <div className="ctxmenu" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()}>
          {([
            ["编辑", "edit"],
            ["重新登录", "relogin"],
            ["服务器线路…", "lines"],
            ["更换图标", "icon"],
            ["修改备注", "remark"],
          ] as [string, DlgKind][]).map(([label, kind]) => (
            <div
              key={kind}
              className="mi"
              onClick={() => {
                setDlg({ kind, srv: menu.srv });
                setMenu(null);
              }}
            >
              {label}
            </div>
          ))}
          <div
            className="mi danger"
            onClick={() => {
              setDlg({ kind: "delete", srv: menu.srv });
              setMenu(null);
            }}
          >
            删除
          </div>
        </div>
      )}

      {dlg?.kind === "edit" && (
        <EditDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "relogin" && (
        <ReloginDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "lines" && <LinesDialog srv={dlg.srv} onClose={() => setDlg(null)} />}
      {dlg?.kind === "icon" && (
        <IconDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={applyLocal} />
      )}
      {dlg?.kind === "remark" && (
        <RemarkDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={applyLocal} />
      )}
      {dlg?.kind === "delete" && (
        <DeleteDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
    </>
  );
}

/* ============================================================
   居中模态弹窗 —— 每个右键项一个,均 .scrim>.dlg。
   ============================================================ */

function Scrim({ onClose, children }: { onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="scrim" onClick={onClose}>
      <div className="dlg" onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

/** 编辑:地址/用户名/密码/备注。备注本机存;填了密码则以该凭据重新登录。 */
function EditDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [server, setServer] = useState(srv.server);
  const [username, setUsername] = useState(srv.user_name);
  const [password, setPassword] = useState("");
  const [remark, setRemark] = useState(getMeta(srv.server).remark || "");
  const [busy, setBusy] = useState(false);

  async function save() {
    if (busy) return;
    setBusy(true);
    try {
      setMeta(srv.server, { remark });
      const reauth = password.trim().length > 0 || server.trim() !== srv.server;
      if (reauth) await login(server.trim(), username.trim(), password);
      onDone(reauth);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        编辑服务器
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="fld">
          <label>服务器地址</label>
          <input className="field" value={server} onChange={(e) => setServer(e.target.value)} />
        </div>
        <div className="fld">
          <label>用户名</label>
          <input className="field" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div className="fld">
          <label>密码(留空 = 不改密码,仅存备注)</label>
          <input
            className="field"
            type="password"
            placeholder="••••••••"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div className="fld" style={{ marginBottom: 0 }}>
          <label>备注(仅本机显示)</label>
          <input className="field" value={remark} onChange={(e) => setRemark(e.target.value)} />
        </div>
        <p className="sv-note">改地址或填密码将以新凭据重新登录该服务器。</p>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={save}>
          {busy ? <span className="spinner" /> : "保存"}
        </button>
      </div>
    </Scrim>
  );
}

/** 重新登录:固定地址,重输凭据。 */
function ReloginDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [username, setUsername] = useState(srv.user_name);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  async function go() {
    if (busy) return;
    setBusy(true);
    try {
      await login(srv.server, username.trim(), password);
      onDone(true);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        重新登录
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="fld">
          <label>服务器地址</label>
          <input className="field" value={srv.server} disabled />
        </div>
        <div className="fld">
          <label>用户名</label>
          <input className="field" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div className="fld" style={{ marginBottom: 0 }}>
          <label>密码</label>
          <input
            className="field"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && go()}
            autoFocus
          />
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={go}>
          {busy ? <span className="spinner" /> : "登录"}
        </button>
      </div>
    </Scrim>
  );
}

/** 服务器线路:核无线路命令 —— 只展示真实活跃线路,同步/添加诚实标注待接后端,不造假数据。 */
function LinesDialog({ srv, onClose }: { srv: AccountInfo; onClose: () => void }) {
  const [hint, setHint] = useState("");
  const stub = () => setHint("线路管理(同步 / 添加 / 探测延迟)待接后端,当前仅显示活跃线路。");
  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        服务器线路 · {srv.user_name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="sv-linebar">
          <button className="btn sm" onClick={stub}>
            <IconRefresh size={14} /> 同步线路
          </button>
          <button className="btn sm" onClick={stub}>
            <IconPlus size={14} /> 添加线路
          </button>
        </div>
        <div className="sv-linerow cur">
          <span className="sv-u">主线 · {srv.server}</span>
          <span className="sv-lat">活跃</span>
        </div>
        <p className="sv-note">
          {hint || "多线路管理与延迟探测(GET /public)待接后端;此处如实显示当前活跃线路,不造假数据。"}
        </p>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>关闭</button>
      </div>
    </Scrim>
  );
}

/** 更换图标:三来源(内置 / 网络图标源 / 本地上传),存本机。 */
function IconDialog({
  srv,
  onClose,
  onDone,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: () => void;
}) {
  const [source, setSource] = useState<"builtin" | "net" | "upload">("builtin");
  const [picked, setPicked] = useState<string>(getMeta(srv.server).icon || "");

  function onFile(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    if (!f) return;
    const r = new FileReader();
    r.onload = () => setPicked(String(r.result));
    r.readAsDataURL(f);
  }

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        更换图标 · {srv.user_name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="seg" style={{ marginBottom: 12 }}>
          {(["builtin", "net", "upload"] as const).map((s) => (
            <span key={s} className={source === s ? "on" : ""} onClick={() => setSource(s)}>
              {s === "builtin" ? "内置图标" : s === "net" ? "网络图标源" : "本地上传"}
            </span>
          ))}
        </div>

        {source === "builtin" && (
          <div className="sv-iconpick">
            <span
              className={`sv-icell${!picked ? " on" : ""}`}
              title="默认"
              onClick={() => setPicked("")}
            >
              <IconServer size={18} />
            </span>
            {GLYPHS.map((g) => (
              <span
                key={g}
                className={`sv-icell${picked === g ? " on" : ""}`}
                onClick={() => setPicked(g)}
              >
                {g}
              </span>
            ))}
          </div>
        )}

        {source === "net" && (
          <>
            <input
              className="field"
              placeholder="粘贴图片 URL(http/https)…"
              value={picked.startsWith("http") ? picked : ""}
              onChange={(e) => setPicked(e.target.value)}
            />
            <p className="sv-note">在线图标库搜索待接;当前支持直接粘贴图片 URL。</p>
          </>
        )}

        {source === "upload" && (
          <label className="sv-upload">
            <input type="file" accept="image/*" onChange={onFile} hidden />
            选择本机图片…
          </label>
        )}

        <div className="sv-icon-preview">
          <span className="sv-sic lg">
            <ServerGlyph icon={picked} size={26} />
          </span>
          <span className="sv-note" style={{ margin: 0 }}>预览</span>
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button
          className="btn primary"
          onClick={() => {
            setMeta(srv.server, { icon: picked });
            onDone();
          }}
        >
          确定
        </button>
      </div>
    </Scrim>
  );
}

/** 修改备注:单输入,本机存。 */
function RemarkDialog({
  srv,
  onClose,
  onDone,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: () => void;
}) {
  const [remark, setRemark] = useState(getMeta(srv.server).remark || "");
  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        修改备注 · {srv.user_name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="fld" style={{ marginBottom: 0 }}>
          <label>备注(仅本机显示,不影响服务器)</label>
          <input
            className="field"
            value={remark}
            onChange={(e) => setRemark(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                setMeta(srv.server, { remark });
                onDone();
              }
            }}
            autoFocus
          />
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button
          className="btn primary"
          onClick={() => {
            setMeta(srv.server, { remark });
            onDone();
          }}
        >
          保存
        </button>
      </div>
    </Scrim>
  );
}

/** 删除:确认后 removeAccount。 */
function DeleteDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  async function del() {
    if (busy) return;
    setBusy(true);
    try {
      await removeAccount(srv.server);
      localStorage.removeItem(metaKey(srv.server));
      onDone(true);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }
  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        删除服务器
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <p className="sv-note" style={{ marginTop: 0 }}>
          确定移除「{srv.user_name}」及其本机备注/图标?此操作不会影响服务器本身。
        </p>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary sv-danger-btn" disabled={busy} onClick={del}>
          {busy ? <span className="spinner" /> : "删除"}
        </button>
      </div>
    </Scrim>
  );
}
