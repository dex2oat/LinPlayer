import { useEffect, useRef, useState } from "react";
import { useSourceForms } from "./sources/sourceForms";
import "./LoginPage.css";

/* ============================================================
   首次登录闸口(草稿 docs/login-drafts.html「方案 B 居中控制台」定稿)。

   ★ 这一页曾经只有三个输入框、只能连 Emby —— 而产品支持六类源加插件源,
     一个只有夸克账号的新用户装完 App 根本进不去。现在它就是「添加服务器页」
     的另一种版式:同一份表单实现(pages/sources/sourceForms),换成居中卡片 + 顶部芯片。

   本页的三条口径(用户 2026-07-23 定):
     1. 不写承诺句 —— 能连什么下面芯片行已经全列出来了,再用一句话复述是废话;
     2. 按钮/输入框**统一 8px 直角**,不混胶囊;
     3. 测试结果**长在按钮上**(测试连接 → 测试中… → ✓ 连接成功),不单开回执块 ——
        回执块一出现会把「添加并进入」整体往下推,点击目标在眼皮底下跳一下。
   ============================================================ */

type Props = {
  /** 加完第一个源 → 直接进首页(用户 2026-07-23 定,不停在页面上继续加)。 */
  onLoggedIn: () => void;
};

/* 芯片行里不出现的源。
   - qrsync:PC 端不提供「扫码搬配置」——那是给手机/TV 那种不好打字的端准备的。
     PC 有键盘有剪贴板,粘一段文本比举着手机扫屏幕快得多,放这儿是把移动端的
     解法搬错了地方。「批量粘贴导入」才是 PC 上换机搬配置的正路。
   - batch:它归底栏那个按钮管。**不能两处都出现** —— 芯片行是"我要连哪种源",
     批量导入是"我不逐个连了,整段粘进来",这是两件事;同一个入口画两遍
     只会让人以为是两个不同的功能。 */
const EXCLUDE = ["qrsync", "batch"];

const Tick = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor"
    strokeWidth={3} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
    <path d="M4 12.5 9.5 18 20 6.5" />
  </svg>
);

export default function LoginPage({ onLoggedIn }: Props) {
  /* 成功后先放一段退场动画再交棒,别让首页"啪"地顶上来。
     ★ 用 ref 记 timer 并在卸载时清:退场途中组件若被卸载(深链等外部路径也会
       改变 session),定时器还在跑就会对着一个不存在的页面调 onLoggedIn。 */
  const [leaving, setLeaving] = useState(false);
  const exitTimer = useRef<number | null>(null);
  useEffect(() => () => { if (exitTimer.current) window.clearTimeout(exitTimer.current); }, []);

  const f = useSourceForms({
    exclude: EXCLUDE,
    onDone: () => {
      setLeaving(true);
      // 与 LoginPage.css 的 lg-leave 时长一致;动画关掉时(reduced-motion)也照走这个节拍。
      exitTimer.current = window.setTimeout(onLoggedIn, 260);
    },
  });

  /* 芯片切换时给表单区一个淡入 —— 换源等于换了一整套字段,没有过渡就是"啪"地
     换一批输入框。key 挂在 sel 上,React 会重建这棵子树,动画自然重放。 */
  return (
    <div className={`app-surface lg-wrap${leaving ? " leaving" : ""}`}>
      <div className="lg-card">
        <div className="lg-hd">
          <div className="lg-brand">
            <span className="lg-mark" aria-hidden>
              <svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor"
                strokeWidth={2.1} strokeLinecap="round" strokeLinejoin="round">
                <path d="M5 3.5 20 12 5 20.5z" />
              </svg>
            </span>
            <span className="lg-name">
              Lin<span>Player</span>
            </span>
          </div>
          <div className="lg-h1">添加第一个片源</div>
        </div>

        {/* 横向滚动而不是换行:插件源的数量是运行时才知道的(装几个插件就有几个),
            换行会让卡片高度跟着插件数抖动,第二行还把表单顶下去。 */}
        <div className="lg-src">
          <div className="lg-chips">
            {f.sources.map((s) => (
              <button
                key={s.id}
                className={`lg-chip${f.sel === s.id ? " on" : ""}`}
                onClick={() => {
                  f.setSel(s.id);
                  f.setErr("");
                  f.setToast("");
                }}
              >
                <span className="ico">{s.icon()}</span>
                {s.label}
              </button>
            ))}
          </div>
        </div>

        <div className="lg-pane" key={f.sel}>
          {/* 失败不走按钮:它得写清「怎么办」,一个按钮的宽度装不下。 */}
          {f.err && (
            <div className="lg-bad" onClick={() => f.setErr("")}>
              <b>连接失败</b>
              <br />
              {f.err}
            </div>
          )}
          {f.fields()}
          <div className="lg-acts">
            {f.sel === "emby" && (
              <button
                className={`btn big${f.testState === "ok" ? " ok" : ""}`}
                style={{ minWidth: 118 }}
                disabled={f.busy}
                onClick={f.doTest}
              >
                {f.testState === "busy" ? (
                  <span className="spinner" />
                ) : f.testState === "ok" ? (
                  <>
                    <Tick />
                    连接成功
                  </>
                ) : (
                  "测试连接"
                )}
              </button>
            )}
            {f.primary("添加并进入")}
          </div>
        </div>

        {/* 批量导入是"另一条路"而不是"另一个源",所以在底栏单独立一个按钮。
            选中时它自己高亮 —— 芯片行里没有它,不给个在态用户就不知道自己在哪。 */}
        <div className="lg-ft">
          <button
            className={`btn ghost${f.sel === "batch" ? " on" : ""}`}
            onClick={() => {
              f.setSel(f.sel === "batch" ? "emby" : "batch");
              f.setErr("");
            }}
          >
            批量粘贴导入
          </button>
        </div>
      </div>

      {f.deepDialog}
      {f.toast && <div className="toast">{f.toast}</div>}
    </div>
  );
}
