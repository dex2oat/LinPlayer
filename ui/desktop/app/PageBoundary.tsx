import { Component, type ReactNode } from "react";
import * as Sentry from "@sentry/react";

/* 页面级错误边界。

   由来:2026-07-16「切到追剧日历直接黑屏,打都打不开」。React 里任何一处渲染抛错都会把
   **整棵树卸载** —— 而本应用的 Tauri 窗口是**透明的**(为了露出垫在下面的 mpv 窗口),
   于是「React 挂了」在屏幕上和「视频没出来」长得一模一样:一片黑,零信息。
   用户只能报「黑屏」,我只能靠读代码猜是哪一行。

   有了它:炸的那一页被就地拦住,侧栏还在(能切走),错误摘要直接写在脸上,
   一页崩不再等于整个 app 崩。**这不是给用户看的美化,是给排查用的证据。**

   ★ 必须是 class:React 至今没有 hooks 版的错误边界(没有 useErrorBoundary)。
   ★ 只吃**渲染期**的抛错。事件处理器/异步 await 里的错它接不到 —— 那些本来就该
     各自 try/catch + say() 报给用户,别指望这里兜底。 */
type Props = { children: ReactNode; /** 换页时重挂 → 上一页的错误态不粘在新页上。 */ resetKey?: string };
type State = { err: Error | null };

export default class PageBoundary extends Component<Props, State> {
  state: State = { err: null };

  static getDerivedStateFromError(err: Error): State {
    return { err };
  }

  componentDidCatch(err: Error, info: { componentStack?: string | null }) {
    // 控制台留全栈:DevTools 里能直接看到是哪个组件哪一行,不用再靠猜。
    console.error("[PageBoundary] 页面渲染崩溃:", err, info.componentStack);
    /* 用户机器上没有 DevTools 可看 —— 这一页崩了,上面那行 console 就烂在他本地。
       componentStack 是「哪个组件炸的」的唯一线索,JS 的 error.stack 里没有它。 */
    Sentry.captureException(err, {
      contexts: { react: { componentStack: info.componentStack ?? "" } },
    });
  }

  componentDidUpdate(prev: Props) {
    if (prev.resetKey !== this.props.resetKey && this.state.err) this.setState({ err: null });
  }

  render() {
    const { err } = this.state;
    if (!err) return this.props.children;
    return (
      <div className="pb-crash">
        <div className="pb-h">这个页面崩了</div>
        <div className="pb-m">{err.message || String(err)}</div>
        <div className="pb-hint">
          左侧可以切到别的页面。把上面这行报给开发者(或按 F12 在 Console 里看完整堆栈)。
        </div>
        <button type="button" className="btn" onClick={() => this.setState({ err: null })}>
          重试这个页面
        </button>
      </div>
    );
  }
}
