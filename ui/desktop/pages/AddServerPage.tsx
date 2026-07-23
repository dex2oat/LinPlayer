import { useSourceForms } from "./sources/sourceForms";
import "./AddServerPage.css";

/* ============================================================
   添加服务器页(桌面主从两栏,草稿 PAGE 6,pin 27/28)。
   左 mdnav 选源类型,右 mdpane 就地出对应表单,取代移动端两次跳转。

   ★ 表单本体已搬进 pages/sources/sourceForms.tsx,和**首次登录闸口**共用一份。
     本文件现在只负责这一页的版式(面包屑 + 主从两栏),不再持有任何源相关状态。
     新增源类型请改 sourceForms.tsx 的 BUILTIN_SOURCES —— 改那一处,两个页面同时生效。
   ============================================================ */

/** onDone(src):src 非空表示刚登录的是文件浏览型源,宿主该直接带去对应页。 */
type Props = { onDone: (src?: "netdisk" | "anirss") => void; onBack: () => void };

export default function AddServerPage({ onDone, onBack }: Props) {
  const f = useSourceForms({ onDone });

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
              {f.groups.map((g) => (
                <div key={g.sec}>
                  <div className="sec">{g.sec}</div>
                  {g.items.map((it) => (
                    <button
                      key={it.id}
                      className={`it${f.sel === it.id ? " on" : ""}`}
                      onClick={() => {
                        f.setSel(it.id);
                        f.setErr("");
                        f.setToast("");
                      }}
                    >
                      {it.icon()}
                      {it.label}
                    </button>
                  ))}
                </div>
              ))}
            </div>
            <div className="mdpane">
              {f.heading()}
              {f.fields()}
              {/* 探测回执:这一页保留完整信息(服务器名/版本/id)——它是"管理"页面,
                  用户在这儿可能同时核对好几台。登录闸口那边只需要一句"连接成功"。 */}
              {f.sel === "emby" && f.probed && (
                <p className="as-ok">
                  探测成功:<b>{f.probed.name}</b> · 版本 {f.probed.version}
                  <span className="as-dim"> · id {f.probed.id}</span>
                  <br />
                  （只是探测,尚未添加。点「添加」才会登录并保存。）
                </p>
              )}
              <div className="as-actions">
                {f.sel === "emby" && (
                  <button className="btn big" disabled={f.busy} onClick={f.doTest}>
                    {f.testState === "busy" ? <span className="spinner" /> : "测试连接"}
                  </button>
                )}
                {f.primary("添加")}
              </div>
            </div>
          </div>
        </div>
        <div style={{ height: 40 }} />
      </div>

      {/* 深链确认门禁:地址 + 用户名必须摆出来给用户看清再点头。 */}
      {f.deepDialog}

      {f.err && <div className="toast error" onClick={() => f.setErr("")}>{f.err}</div>}
      {f.toast && <div className="toast">{f.toast}</div>}
    </>
  );
}
