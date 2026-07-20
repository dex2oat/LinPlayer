/* ============================================================
   焦点基座 —— norigin-spatial-navigation 的初始化与约定。

   TV 端最容易翻车的不是审美是焦点,而焦点问题在静态稿上完全看不出来。
   这里把库的硬约束一次性钉死,页面只管用 useFocusable,别各自改配置。
   ============================================================ */

import {
  GetBoundingClientRectAdapter,
  init,
  setKeyMap,
} from "@noriginmedia/norigin-spatial-navigation";

/** 壳(Android Activity)发给前端的键。见下方 emit 契约。 */
export const TV_KEY_EVENT = "lp:tvkey";
export type TvKey =
  | "back"
  | "menu"
  | "play"
  | "pause"
  | "playpause"
  | "stop"
  | "next"
  | "prev"
  | "ff"
  | "rew";

let inited = false;

/** 应用启动时调一次。重复调用无害(内部有守卫)。 */
export function initTvFocus() {
  if (inited) return;
  inited = true;

  init({
    /* ★ 必须换掉默认的布局测量,不是可选项。
       默认适配器用 offsetLeft/offsetTop 那套,**读不到 CSS transform 和 zoom**。
       我们两样都用:焦点态是 `.fx.foc{transform:scale(1.06)}`,根容器用 zoom 缩放。
       不换的话库拿到的是变换前的矩形,方向判定算错邻居 ——
       表现为"右边明明有卡,按右却跳到下一行",而且**静态稿上完全看不出来**。

       ★ 3.2.1 起 `useGetBoundingClientRect: true` 已标记 deprecated
         (内部就是转成这个适配器),直接给 layoutAdapter 才是当前写法。 */
    layoutAdapter: GetBoundingClientRectAdapter,

    /* 遥控器长按方向键会疯狂重复。不节流的话:一路冲到列表尽头,而且掉帧。
       120ms 是"按住能连续走、但走得动眼睛跟得上"的经验值。 */
    throttle: 120,
    throttleKeypresses: true,

    /* 让库同时调 HTMLElement.focus() —— 原生 <input> 要靠它才能升起系统输入法,
       滚动容器也要靠它才有原生可访问性。 */
    shouldFocusDOMNode: true,

    /* ★ 别关 saveLastFocusedChild(默认 true)。
       "焦点掉到 body → 遥控器彻底失灵"是 TV 最经典的 P0,
       它 + autoRestoreFocus 就是解法。别自己写焦点记忆,写不过库。 */

    /* 开发期把焦点框和方向判定画出来。生产必须关 —— 它会往每个可聚焦元素上画覆盖层。 */
    visualDebug: import.meta.env.DEV && localStorage.getItem("lp.tv.debugFocus") === "1",
  });

  /* ★ keyCode 各厂商不统一:标准 D-pad 是 37-40,但部分机顶盒用 400-403,
     还有厂商把 OK 键映射成 13 之外的值。这里给的是**标准 + 已知常见变体**的并集,
     真机上如果方向键不响应,开 localStorage['lp.tv.logKeys']='1' 把实际 keyCode
     打出来再往这里补 —— 别猜。 */
  setKeyMap({
    left: [37, 214, 205, 218, 4],
    right: [39, 213, 206, 217, 5],
    up: [38, 211, 203, 215, 29460],
    down: [40, 212, 204, 216, 29461],
    enter: [13, 29443, 23],
  });

  if (localStorage.getItem("lp.tv.logKeys") === "1") {
    window.addEventListener("keydown", (e) =>
      console.log("[tvkey]", e.keyCode, e.key, e.code),
    );
  }
}

/* ------------------------------------------------------------
   壳键契约。

   ★ 这两条通道必须在 apps/android 的 Activity 里先落,否则整个 TV 端后期改不动:
     - KEYCODE_BACK 被 Activity 自己吃掉,WebView 根本收不到 → 返回键全站失灵
     - 媒体键(播放/暂停/上一集/下一集)同理

   壳侧做法(onKeyDown 里):
     webView.evaluateJavascript("window.__lpTvKey && window.__lpTvKey('back')", null)
   并 return true 吃掉该键。

   前端这边把它转成 window 事件,页面用 onTvKey 订阅。
   ------------------------------------------------------------ */

declare global {
  interface Window {
    __lpTvKey?: (k: TvKey) => void;
  }
}

/** 装上壳→前端的入口。启动时调一次。 */
export function installTvKeyBridge() {
  window.__lpTvKey = (k: TvKey) => {
    window.dispatchEvent(new CustomEvent(TV_KEY_EVENT, { detail: k }));
  };

  /* 桌面 Tauri / 浏览器里没有壳,用键盘兜底 —— TV UI 目前就是靠这条在 PC 上开发的。
     Esc/Backspace = 返回,方便不接遥控器也能走完整个流程。 */
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape" || e.key === "Backspace") {
      const t = e.target as HTMLElement | null;
      // 输入框里的退格是删字,不是返回
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      e.preventDefault();
      window.__lpTvKey?.("back");
    }
    if (e.key === "ContextMenu") window.__lpTvKey?.("menu");
  });
}

/* ------------------------------------------------------------
   返回键消费栈
   ------------------------------------------------------------ */

/** 返回键处理器,从内到外依次询问;返回 true = 我吃掉了,别再往外传。 */
const backHandlers: Array<() => boolean> = [];

/** 注册一层返回键处理(面板/对话框挂载时调)。返回退订函数。
 *
 *  ★ 为什么需要这个:App 原来无条件把 back 变成「退一层路由」,
 *    于是**面板开着时按返回,面板没关、整个页面先退掉了** ——
 *    用户只想关掉字幕面板,结果回到了上一页。
 *    这是全站每个面板的通病(不是某一页的),所以解法必须在这一层,
 *    不能靠每个页面自己记得拦。 */
export function pushBackHandler(fn: () => boolean): () => void {
  backHandlers.push(fn);
  return () => {
    const i = backHandlers.lastIndexOf(fn);
    if (i >= 0) backHandlers.splice(i, 1);
  };
}

/** 由最内层向外询问。true = 已被消费,调用方不要再退页面。 */
export function consumeBack(): boolean {
  for (let i = backHandlers.length - 1; i >= 0; i--) {
    try {
      if (backHandlers[i]()) return true;
    } catch {
      /* 某一层抛错不该让返回键整个失灵 —— 那是遥控器彻底没反应的 P0。 */
    }
  }
  return false;
}

/** 订阅壳键。返回退订函数,直接丢给 useEffect 的 cleanup。 */
export function onTvKey(fn: (k: TvKey) => void): () => void {
  const h = (e: Event) => fn((e as CustomEvent<TvKey>).detail);
  window.addEventListener(TV_KEY_EVENT, h);
  return () => window.removeEventListener(TV_KEY_EVENT, h);
}

/* ------------------------------------------------------------
   1920 基准缩放。
   ------------------------------------------------------------ */

/** 把 .tv-app 等比缩放到实际屏幕。
 *  ★ 用 zoom 不用 transform:scale —— transform 会让元素成为后代 fixed 的包含块,
 *    整棵树的 position:fixed 都会以它为参照而不是视口(PC 端就栽过这个)。 */
export function applyTvScale(el: HTMLElement) {
  const fit = () => {
    const z = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    el.style.zoom = String(z);
  };
  fit();
  window.addEventListener("resize", fit);
  return () => window.removeEventListener("resize", fit);
}
