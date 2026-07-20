import { Component, type ReactNode } from "react";

/* 页面级错误边界。

   由来同 PC 端:React 里任何一处渲染抛错会把**整棵树卸载**。TV 上这件事更致命 ——
   桌面至少还剩个窗口边框,机顶盒上整屏纯黑,而**遥控器也一起没反应了**
   (焦点树跟着树一起没了),用户只能拔电源。

   有了它:炸的那一页被就地拦住,导航轨还在(还能按左切走),错误摘要写在脸上。
   ★ 只吃**渲染期**的抛错。事件处理器/异步 await 里的错它接不到。 */
type Props = { children: ReactNode; resetKey?: string };
type State = { err: Error | null };

export default class PageBoundary extends Component<Props, State> {
  state: State = { err: null };

  static getDerivedStateFromError(err: Error): State {
    return { err };
  }

  componentDidCatch(err: Error, info: { componentStack?: string | null }) {
    console.error("[PageBoundary] 页面渲染崩溃:", err, info.componentStack);
  }

  componentDidUpdate(prev: Props) {
    if (prev.resetKey !== this.props.resetKey && this.state.err) this.setState({ err: null });
  }

  render() {
    const { err } = this.state;
    if (!err) return this.props.children;
    return (
      <div style={{ padding: "80px 64px", maxWidth: 1100 }}>
        <div style={{ fontSize: 40, fontWeight: 680, marginBottom: 14 }}>这个页面崩了</div>
        <div style={{ fontSize: 22, color: "var(--danger)", marginBottom: 18 }}>
          {err.message || String(err)}
        </div>
        <div style={{ fontSize: 19, color: "var(--tv-ink-2)", lineHeight: 1.6 }}>
          按左键回到导航轨可以切到别的页面。把上面这行报给开发者。
        </div>
      </div>
    );
  }
}
