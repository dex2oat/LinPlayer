import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import QRCode from "qrcode";
import {
  type BatchAddResult,
  type ParsedServerBlock,
  type ServerInfo,
  batchAddServers,
  batchParse,
  configExportQr,
  configImportQr,
  login,
  parseDeepLink,
  quarkScanPoll,
  quarkScanStart,
  sourceLogin,
  startupDeepLink,
  testConnection,
  updateAccount,
} from "../lib/api";
import { IconCloud, IconFile, IconServer } from "../app/icons";
import "./AddServerPage.css";

/* ============================================================
   添加服务器页(桌面主从两栏,草稿 PAGE 6,pin 27/28)。
   左 mdnav 选源类型,右 mdpane 就地出对应表单,取代移动端两次跳转。
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

/* ★ api.ts 里的 ParsedServerBlock 类型与 Rust 侧 server_batch::ParsedServerBlock **对不上**
   (那边写的是 name/urls/remark,核层实际是 username/password/lines/danmaku_lines)。
   api.ts 非本页所有,不擅改;这里按核层真实结构声明,过 invoke 时窄转。
   块本身原样从 batch_parse 拿、原样喂 batch_add_servers,不在前端重组,故运行时安全。 */
type ParsedLine = { name: string; url: string };
type Block = {
  username: string | null;
  password: string | null;
  lines: ParsedLine[];
  danmaku_lines: ParsedLine[];
};
const asBlocks = (b: ParsedServerBlock[]) => b as unknown as Block[];
const asApi = (b: Block[]) => b as unknown as ParsedServerBlock[];

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

/** 二维码画布:qrcode 已在 package.json 里(之前一直没人 import,白装)。 */
function Qr({ data, size = 176 }: { data: string; size?: number }) {
  const [img, setImg] = useState("");
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    setErr("");
    QRCode.toDataURL(data, { width: size, margin: 1, errorCorrectionLevel: "M" })
      .then((d) => alive && setImg(d))
      // 载荷过长(配置多到超出二维码容量)时会失败 —— 必须说出来,不能白框糊弄。
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [data, size]);
  if (err) return <p className="as-warn" style={{ margin: 0 }}>二维码生成失败:{err}</p>;
  return img ? (
    <img className="as-qr" src={img} width={size} height={size} alt="二维码" />
  ) : (
    <span className="spinner" />
  );
}

export default function AddServerPage({ onDone, onBack }: Props) {
  const [sel, setSel] = useState<TypeId>("emby");

  // 各表单共用输入(切换类型时保留,填过的地址账号不用重敲)。
  const [server, setServer] = useState("https://");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [note, setNote] = useState("");
  const [cookie, setCookie] = useState("");
  const [batchText, setBatchText] = useState("");
  const [qrPayload, setQrPayload] = useState("");
  const [exportText, setExportText] = useState("");
  const [probed, setProbed] = useState<ServerInfo | null>(null);

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

  /* ---------- linplayer:// 深链(安全门禁) ----------
     ★ 深链可能来自任何网页/聊天窗口。解析出来 **不等于** 可以直接加 ——
     必须弹确认框把服务器地址和用户名摆给用户看,他点头才 batch_add_servers。
     直接静默添加 = 任意网页能把用户钉到攻击者的服务器上。 */
  const [deep, setDeep] = useState<{ name: string | null; block: Block } | null>(null);

  useEffect(() => {
    (async () => {
      try {
        // ★ startup_deep_link 的 Rust 签名是 -> Option<String>(原始 URL),
        // api.ts 却把它标成 DeepLinkAddServer|null —— 那边类型写错了(已上报)。
        // 这里按核层实际形态窄转,再交给 parse_deep_link 真正解析。
        const url = (await startupDeepLink()) as unknown as string | null;
        if (!url) return;
        const link = await parseDeepLink(url);
        if (!link) return;
        setDeep({ name: link.name, block: asBlocks([link.block])[0] });
      } catch (e) {
        setErr(String(e)); // 解析失败要说出来,别让用户干等一个不出现的确认框
      }
    })();
  }, []);

  const confirmDeep = () =>
    run(async () => {
      if (!deep) return;
      const r = await batchAddServers(asApi([deep.block]), null, null, deep.name);
      setDeep(null);
      const bad = r.filter((x) => x.error);
      if (bad.length) {
        setErr(bad.map((x) => `${x.name}:${x.error}`).join(" / "));
        return;
      }
      setToast(`已添加 ${r.length} 个服务器`);
      window.setTimeout(() => onDone(), 800);
    });

  // ---------- Emby ----------
  /* ★ 测试连接**只探测,不添加**。以前这里调的是 login() —— 它会 upsert 账号、
     落盘、还把活跃会话切过去,然后只回一句「连接成功」,用户根本没说要加。
     test_connection 是专为这个 pin 写的:登录前调用,不碰会话不落账号。 */
  const doTest = () =>
    run(async () => {
      const info = await testConnection(server.trim());
      setProbed(info);
      setToast(`连接成功:${info.name} · ${info.version}`);
    });

  const doAdd = () =>
    run(async () => {
      const res = await login(server.trim(), username, password);
      // login 没有 note 参数(核层确实如此),但备注本身是落库的 —— 加完补一刀。
      const n = note.trim();
      if (n) await updateAccount(res.server, { remark: n });
      onDone();
    });

  const submitSource = (kind: "Openlist" | "Feiniu" | "Anirss") =>
    run(async () => {
      await sourceLogin(kind, server.trim(), username, password, null);
      onDone(kind === "Anirss" ? "anirss" : "netdisk");
    });

  // ---------- 夸克:扫码 / Cookie 两种方式 ----------
  const [quarkWay, setQuarkWay] = useState<"scan" | "cookie">("scan");
  const [scan, setScan] = useState<{ device_id: string; qr_data: string; query_token: string } | null>(null);
  const [scanMsg, setScanMsg] = useState("");
  const pollRef = useRef<number | null>(null);

  const stopPoll = useCallback(() => {
    if (pollRef.current != null) window.clearInterval(pollRef.current);
    pollRef.current = null;
  }, []);
  // 离页/切换方式必须停轮询,否则弹窗关了它还在后台每 2s 打夸克。
  useEffect(() => stopPoll, [stopPoll]);
  useEffect(() => {
    if (sel !== "quark" || quarkWay !== "scan") stopPoll();
  }, [sel, quarkWay, stopPoll]);

  const startScan = () =>
    run(async () => {
      stopPoll();
      setScanMsg("请用夸克 App 扫码并确认登录");
      const s = await quarkScanStart();
      setScan(s);
      pollRef.current = window.setInterval(async () => {
        try {
          const ok = await quarkScanPoll(s.device_id, s.query_token);
          if (!ok) return; // false = 还没确认,继续轮询
          stopPoll();
          setScanMsg("登录成功");
          onDone("netdisk"); // poll 返回 true 时夸克源已装为活跃源
        } catch (e) {
          // 二维码过期/被拒都会走这里 —— 停下并说明,别无声空转。
          stopPoll();
          setErr(String(e));
          setScanMsg("扫码失败,请点「刷新二维码」重试");
        }
      }, 2000);
    });

  const submitQuarkCookie = () =>
    run(async () => {
      await sourceLogin("Quark", "", "", "", cookie);
      onDone("netdisk");
    });

  // ---------- 批量解析导入(两段式:先解析给用户核对,确认后才登录落盘) ----------
  const [blocks, setBlocks] = useState<Block[] | null>(null);
  const [fbUser, setFbUser] = useState("");
  const [fbPass, setFbPass] = useState("");
  const [fbName, setFbName] = useState("");
  const [results, setResults] = useState<BatchAddResult[] | null>(null);

  const doParse = () =>
    run(async () => {
      setResults(null);
      const b = asBlocks(await batchParse(batchText));
      setBlocks(b);
      if (!b.length) setToast("没解析出任何服务器,检查一下文本格式");
    });

  const doBatchAdd = () =>
    run(async () => {
      if (!blocks?.length) return;
      const r = await batchAddServers(
        asApi(blocks),
        fbUser.trim() || null,
        fbPass || null,
        fbName.trim() || null,
      );
      setResults(r);
      // 全绿才跳走;有失败就留在页面上让用户看结果(补用户名再来一次)。
      if (r.length && r.every((x) => !x.error)) window.setTimeout(() => onDone(), 900);
    });

  // ---------- 扫码搬配置 ----------
  const importQr = () =>
    run(async () => {
      const n = await configImportQr(qrPayload.trim());
      setToast(`已导入 ${n} 个账号`);
      window.setTimeout(() => onDone(), 1000);
    });

  const exportQr = () =>
    run(async () => {
      setExportText(await configExportQr());
    });

  const spin = (label: string) => (busy ? <span className="spinner" /> : label);

  // 地址 + 用户名 + 密码(Emby 与网盘登录型共用)。
  const creds = (optional = false) => (
    <>
      <div className="fld">
        <label>服务器地址</label>
        <input
          className="field"
          placeholder="https://host:port"
          value={server}
          onChange={(e) => {
            setServer(e.target.value);
            setProbed(null); // 地址改了,上次的探测结果就不作数了
          }}
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
            {probed && (
              <p className="as-ok">
                探测成功:<b>{probed.name}</b> · 版本 {probed.version}
                <span className="as-dim"> · id {probed.id}</span>
                <br />
                （只是探测,尚未添加。点「添加」才会登录并保存。）
              </p>
            )}
            <div className="as-actions">
              <button className="pill" disabled={busy} onClick={doTest}>
                {spin("测试连接")}
              </button>
              <button className="btn primary" disabled={busy} onClick={doAdd}>
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
            <p className="hint">推荐扫码登录；也可粘贴浏览器 Cookie。</p>
            <div className="seg" style={{ marginBottom: 14 }}>
              {(["scan", "cookie"] as const).map((w) => (
                <span key={w} className={quarkWay === w ? "on" : ""} onClick={() => setQuarkWay(w)}>
                  {w === "scan" ? "扫码登录" : "Cookie"}
                </span>
              ))}
            </div>

            {quarkWay === "scan" ? (
              <div className="as-scan">
                {scan ? <Qr data={scan.qr_data} /> : <div className="as-qr placeholder">点下方按钮生成二维码</div>}
                <div className="as-scan-side">
                  <p className="hint" style={{ margin: 0 }}>{scanMsg || "用夸克 App 扫码,确认后自动完成登录。"}</p>
                  <button className="btn primary" disabled={busy} onClick={startScan}>
                    {spin(scan ? "刷新二维码" : "生成二维码")}
                  </button>
                </div>
              </div>
            ) : (
              <>
                <p className="hint">浏览器登录夸克后复制整段 Cookie 粘贴到下方。</p>
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
                  <button className="btn primary" disabled={busy} onClick={submitQuarkCookie}>
                    {spin("添加")}
                  </button>
                </div>
              </>
            )}
          </>
        );

      case "batch":
        return (
          <>
            <h4>批量解析导入</h4>
            <p className="hint">
              粘贴分享文本 → <b>解析</b>(只解析,不登录不落盘)→ 核对无误后 <b>添加</b>。
            </p>
            <div className="fld">
              <label>服务器列表 / 分享文本</label>
              <textarea
                className="field"
                rows={7}
                placeholder={"线路1|https://a.lan:8096\n线路2|https://b.lan:8096\n账号:user\n密码:pass"}
                value={batchText}
                onChange={(e) => setBatchText(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button className="pill" disabled={busy || !batchText.trim()} onClick={doParse}>
                {spin("解析")}
              </button>
            </div>

            {blocks && blocks.length > 0 && (
              <>
                <h4 style={{ marginTop: 20 }}>核对（{blocks.length} 个服务器）</h4>
                <div className="as-blocks">
                  {blocks.map((b, i) => {
                    const r = results?.[i];
                    return (
                      <div key={i} className="as-block">
                        <div className="as-block-hd">
                          <b>{b.lines[0]?.name || "(未命名)"}</b>
                          <span className="as-dim">{b.username || "缺用户名(用下方兜底)"}</span>
                          {r && (
                            <span className={`as-rst${r.error ? " bad" : ""}`}>
                              {r.error ? `✕ ${r.error}` : "✓ 已添加"}
                            </span>
                          )}
                        </div>
                        {b.lines.map((l, k) => (
                          <div key={k} className="as-line">
                            <span className="as-dim">{l.name}</span> {l.url}
                          </div>
                        ))}
                        {b.danmaku_lines.length > 0 && (
                          <div className="as-line as-dim">
                            弹幕线路 × {b.danmaku_lines.length}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>

                <p className="hint" style={{ marginTop: 14 }}>
                  兜底凭据:套用到上面所有<b>没解析出用户名</b>的块（解析到的以文本里的为准）。
                </p>
                <div className="as-grid3">
                  <div className="fld">
                    <label>兜底用户名</label>
                    <input className="field" value={fbUser} onChange={(e) => setFbUser(e.target.value)} />
                  </div>
                  <div className="fld">
                    <label>兜底密码</label>
                    <input className="field" type="password" value={fbPass} onChange={(e) => setFbPass(e.target.value)} />
                  </div>
                  <div className="fld">
                    <label>兜底显示名（可选）</label>
                    <input className="field" value={fbName} onChange={(e) => setFbName(e.target.value)} />
                  </div>
                </div>
                <div className="as-actions">
                  <button className="btn primary" disabled={busy} onClick={doBatchAdd}>
                    {spin(`添加这 ${blocks.length} 个`)}
                  </button>
                </div>
              </>
            )}
          </>
        );

      case "qrsync":
        return (
          <>
            <h4>扫码搬配置</h4>
            <p className="hint">
              在本机<b>导出</b>成二维码,另一台设备扫走(离线直传凭据);或把对方的 LPSYNC1 载荷粘到下方<b>导入</b>。
            </p>
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
            {/* 扫「进来」要摄像头,桌面端没有 —— 故导入侧保留文本粘贴,这是真实约束不是偷懒。 */}
            <p className="hint" style={{ marginTop: 10 }}>
              桌面端无摄像头,故「导入」用文本粘贴;「导出」出二维码给手机扫。
            </p>
            {exportText && (
              <div className="as-export">
                <Qr data={exportText} size={200} />
                <div className="fld" style={{ flex: 1, marginBottom: 0 }}>
                  <label>本机配置载荷（也可复制文本到另一台设备导入）</label>
                  <textarea className="field" rows={5} readOnly value={exportText} />
                </div>
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

      {/* 深链确认门禁:地址 + 用户名必须摆出来给用户看清再点头。 */}
      {deep && (
        <div className="scrim" onClick={() => setDeep(null)}>
          <div className="dlg" onClick={(e) => e.stopPropagation()}>
            <div className="dhd">确认添加服务器?</div>
            <div className="dbd">
              <p className="as-warn" style={{ marginBottom: 12 }}>
                这是通过 <b>linplayer://</b> 链接发起的请求,可能来自任意网页或聊天窗口。
                请确认下面的地址和用户名确实是你想添加的。
              </p>
              {deep.name && (
                <div className="fld">
                  <label>名称</label>
                  <input className="field" value={deep.name} disabled />
                </div>
              )}
              <div className="fld">
                <label>用户名</label>
                <input className="field" value={deep.block.username || "(未提供,添加会失败)"} disabled />
              </div>
              <div className="fld" style={{ marginBottom: 0 }}>
                <label>服务器地址（{deep.block.lines.length} 条线路）</label>
                {deep.block.lines.map((l, i) => (
                  <input key={i} className="field" style={{ marginTop: i ? 6 : 0 }} value={`${l.name} · ${l.url}`} disabled />
                ))}
              </div>
            </div>
            <div className="dft">
              <button className="btn" onClick={() => setDeep(null)}>取消</button>
              <button className="btn primary" disabled={busy} onClick={confirmDeep}>
                {spin("确认添加")}
              </button>
            </div>
          </div>
        </div>
      )}

      {err && <div className="toast error" onClick={() => setErr("")}>{err}</div>}
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
