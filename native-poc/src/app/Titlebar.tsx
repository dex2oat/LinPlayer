import { useEffect, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";

/**
 * 自绘标题栏(tauri.conf.json 已 decorations:false)。
 * 用户 2026-07-16:「默认标题栏太丑,自绘一个:应用图标 + 名字 + 最小化/窗口化/退出」。
 *
 * 结构:[图标 + LinPlayer]（可拖动） …弹性拖动区… [最小化][最大化/还原][关闭]
 * - 拖动:brand + 中间弹性区带 data-tauri-drag-region → 拖它们移动窗口(需 allow-start-dragging)。
 * - 按钮:minimize / toggleMaximize / close(权限已在 capabilities/default.json 放行)。
 * - 播放时本组件不渲染(见 App:{!playing && <Titlebar/>}),让 mpv 全屏铺满,不跟播放器顶栏打架。
 */
export default function Titlebar() {
  const [maxed, setMaxed] = useState(false);
  const win = getCurrentWindow();

  useEffect(() => {
    let un: (() => void) | undefined;
    win.isMaximized().then(setMaxed).catch(() => {});
    // 拖拽/双击/系统热键都可能改变最大化态 → 跟着窗口 resize 事件回读,别只在点击时翻。
    win
      .onResized(() => {
        win.isMaximized().then(setMaxed).catch(() => {});
      })
      .then((f) => (un = f))
      .catch(() => {});
    return () => un?.();
    // getCurrentWindow() 每次同一实例,不入依赖。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="titlebar">
      <div className="tb-brand" data-tauri-drag-region>
        <span className="tb-logo" aria-hidden>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none">
            <rect x="1.5" y="1.5" width="21" height="21" rx="6" fill="var(--accent)" />
            <path d="M9.5 8.2v7.6l6.3-3.8-6.3-3.8z" fill="var(--accent-ink)" />
          </svg>
        </span>
        <span className="tb-name">LinPlayer</span>
      </div>

      {/* 弹性拖动区:占满中间,拖它就是拖窗口。 */}
      <div className="tb-drag" data-tauri-drag-region />

      <div className="tb-ctrls">
        <button className="tb-btn" title="最小化" onClick={() => void win.minimize()}>
          <svg width="10" height="10" viewBox="0 0 10 10">
            <rect x="0" y="4.5" width="10" height="1" fill="currentColor" />
          </svg>
        </button>
        <button
          className="tb-btn"
          title={maxed ? "还原" : "最大化"}
          onClick={() => void win.toggleMaximize()}
        >
          {maxed ? (
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1">
              <rect x="0.5" y="2.5" width="6" height="6" rx="1" />
              <path d="M3 2.5V1.5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v4a1 1 0 0 1-1 1h-1" />
            </svg>
          ) : (
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1">
              <rect x="0.5" y="0.5" width="9" height="9" rx="1" />
            </svg>
          )}
        </button>
        <button className="tb-btn danger" title="关闭" onClick={() => void win.close()}>
          <svg width="10" height="10" viewBox="0 0 10 10" stroke="currentColor" strokeWidth="1.1">
            <path d="M1 1l8 8M9 1l-8 8" />
          </svg>
        </button>
      </div>
    </div>
  );
}
