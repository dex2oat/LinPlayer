/* ============================================================
   手机控制台 → 电视端的接收侧。

   手机上那一页(crates/core/src/companion.html)按下的每个键,先到 Rust
   (apps/android 的 companion_call),再由 Rust `emit` 到这里。这一层只做一件事:
   **把它变成电视上"真的按了一下遥控器"**。

   ★ 为什么按键要合成 KeyboardEvent 而不是直接调焦点库的 API:
     库的导航入口(smartNavigate)不是公开 API,公开的只有 setFocus(focusKey) ——
     那要求调用方知道下一个焦点是谁,等于把整棵焦点树的邻接关系在这里再算一遍。
     而库自己是在 **window 的 keydown** 上监听的(核对过 dist 源码),
     所以合成一个带正确 keyCode 的事件,走的就是和真遥控器**完全同一条**代码路径。

   ★ keyCode 必须自己 defineProperty 塞:KeyboardEvent 构造器认 `key`/`code`,
     但 **keyCode 是只读的**,构造参数里给了也不生效(库读的恰恰是 keyCode)。
   ============================================================ */

import { listen } from "@tauri-apps/api/event";
import { setThemePref } from "@shared/api";

/** 与 focus.ts 的 setKeyMap 对齐:这里发标准键码,那边的映射表里一定有。 */
const KEYCODE: Record<string, { key: string; code: number }> = {
  up: { key: "ArrowUp", code: 38 },
  down: { key: "ArrowDown", code: 40 },
  left: { key: "ArrowLeft", code: 37 },
  right: { key: "ArrowRight", code: 39 },
  enter: { key: "Enter", code: 13 },
};

function press(k: string) {
  const m = KEYCODE[k];
  if (!m) return;
  const ev = new KeyboardEvent("keydown", { key: m.key, bubbles: true, cancelable: true });
  Object.defineProperty(ev, "keyCode", { get: () => m.code });
  Object.defineProperty(ev, "which", { get: () => m.code });
  /* 派发到 activeElement 而不是 window:输入框拿着 DOM 焦点时(FocusInput),
     手机上按左右应该是移光标,和真遥控器一致 —— 派到 window 就绕过输入框了。 */
  (document.activeElement ?? window).dispatchEvent(ev);
  window.dispatchEvent(new KeyboardEvent("keyup", { key: m.key }));
}

/** 装上接收端。App 挂载时调一次;返回退订函数。 */
export function installRemote(handlers: {
  /** 手机点了搜索结果:电视去打开这个条目。 */
  onOpen: (itemId: string) => void;
  /** 手机按了首页。 */
  onHome: () => void;
  /** 账号表被手机改了(登录/切换/删除),重新问一次会话。 */
  onAccountsChanged: () => void;
}): () => void {
  const un: Array<Promise<() => void>> = [];

  /* 把当前主题镜像给核层。手机控制台读不到 WebView 的 localStorage,
     不报这一次的话它只能显示一个猜的默认值 —— 用户在手机上看到的"当前主题"是错的。 */
  void setThemePref(localStorage.getItem("lp.theme") === "light" ? "light" : "dark");

  un.push(
    listen<string>("lp://remote-key", (e) => {
      const k = e.payload;
      if (k === "back") window.__lpTvKey?.("back");
      else if (k === "home") handlers.onHome();
      else press(k);
    }),
  );

  un.push(listen<string>("lp://remote-open", (e) => handlers.onOpen(e.payload)));

  un.push(
    listen<string>("lp://remote-theme", (e) => {
      /* 直接写 DOM + localStorage,不经 useTheme:主题的 React 副本每个页面各持一份
         (见 @shared/theme),挨个通知不现实。写权威源 + 立即生效,页面下次读到的就是新值。 */
      const t = e.payload === "light" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", t);
      localStorage.setItem("lp.theme", t);
    }),
  );

  un.push(listen("lp://accounts-changed", () => handlers.onAccountsChanged()));

  return () => {
    for (const p of un) p.then((f) => f()).catch(() => {});
  };
}
