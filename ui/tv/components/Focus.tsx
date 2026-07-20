/* ============================================================
   焦点原语 —— 全站的可聚焦项 / 横向行 / 纵向页 / 焦点边界都走这四个。

   为什么要自己包一层而不是各页直接用 useFocusable:
   「焦点移出可视区要把容器滚过去」这件事每个列表都要做,散着写必然有页忘记,
   而忘记的表现是**焦点看不见了但按键还在生效** —— 用户会以为遥控器坏了。

   ★ 库没有 onChildFocused 这种东西(我一开始就是这么写的,是错的)。
     官方的滚动模式是「父把 onFocus 回调传给子」。这里用 React context 传,
     省得每个页面手工把回调一层层往下递 —— 递漏一个就是一段不会滚的列表。
   ============================================================ */

import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import {
  FocusContext,
  useFocusable,
  type FocusableComponentLayout,
} from "@noriginmedia/norigin-spatial-navigation";

/** 子项聚焦时通知所在的滚动容器。null = 不在任何滚动容器里(比如导航轨)。 */
const ScrollNotify = createContext<((node: HTMLElement) => void) | null>(null);

/* ------------------------------------------------------------
   可聚焦项
   ------------------------------------------------------------ */

type ItemProps = {
  children: ReactNode;
  className?: string;
  /** 焦点类名。默认 `foc`,对应 tv.css 里全站唯一那套焦点态。 */
  focusClass?: string;
  onEnter?: () => void;
  /** 本项获得焦点时。给「焦点走到倒数第二行就预取下一页」这类无限加载用 ——
   *  没有它就只能拿 IntersectionObserver + 一个量出来的魔数当近似。 */
  onFocus?: () => void;
  focusKey?: string;
  /** 不可聚焦(如不可用的版本卡):保留显示,但跳过焦点位。 */
  disabled?: boolean;
  style?: React.CSSProperties;
  /** 挂载时抢焦点。一页只该有一个。 */
  autoFocus?: boolean;
};

export function FocusItem({
  children,
  className = "",
  focusClass = "foc",
  onEnter,
  onFocus,
  focusKey,
  disabled,
  style,
  autoFocus,
}: ItemProps) {
  const notify = useContext(ScrollNotify);
  const { ref, focused, focusSelf } = useFocusable<object, HTMLDivElement>({
    focusable: !disabled,
    focusKey,
    onEnterPress: onEnter,
    onFocus: (layout: FocusableComponentLayout) => {
      notify?.(layout.node as HTMLElement);
      onFocus?.();
    },
  });

  useEffect(() => {
    if (autoFocus && !disabled) focusSelf();
  }, [autoFocus, disabled, focusSelf]);

  return (
    <div
      ref={ref}
      style={style}
      className={`${className} ${focused ? focusClass : ""}`.trim()}
    >
      {children}
    </div>
  );
}

/* ------------------------------------------------------------
   横向行
   ------------------------------------------------------------ */

/** 平移而不是 scrollLeft —— scrollLeft 在机顶盒 WebView 上触发整层重绘,
 *  transform 走合成器。差别在弱机上肉眼可见。 */
export function FocusRow({
  children,
  className = "",
  trackClass = "track breathe",
  focusKey,
}: {
  children: ReactNode;
  className?: string;
  trackClass?: string;
  focusKey?: string;
}) {
  const trackRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<HTMLDivElement>(null);
  /* ★ 行套在列里时,子项只能看见**最近的**那个 ScrollNotify(也就是本行的)。
     不往上冒的话:行内左右滚得好好的,但整行永远不会被带进视野 ——
     往下走几行之后焦点跑到屏幕外,按键还在生效,用户以为遥控器坏了。
     (这正是我在本文件开头写的那个失败模式,自己先踩了一遍。) */
  const outerNotify = useContext(ScrollNotify);

  const { ref, focusKey: fk } = useFocusable<object, HTMLDivElement>({
    focusKey,
    saveLastFocusedChild: true,
    trackChildren: true,
    /* ★ 容器**必须保持 focusable(默认 true)**,不能设 false。
       库的方向导航只在「同一个 parent 下 focusable 的兄弟」里找目标
       (smartNavigate 的 siblings 过滤器带 component.focusable),
       容器设 false 就从候选里被剔掉 → **焦点永远进不去这一行**。
       落到容器上时库会自己往下钻到子项(lastFocusedChild / preferredChild)。
       实测过:设了 false 之后按↓完全不动,而截图上一点都看不出来。 */
  });

  const notify = (node: HTMLElement) => {
    const track = trackRef.current;
    const view = viewRef.current;
    if (!track || !view) return;
    const viewR = view.getBoundingClientRect();
    const r = node.getBoundingClientRect();
    const left = r.left - viewR.left;
    const cur = readTranslate(track, "X");
    const z = zoomOf(view); // gBCR 是设备 px,transform 是 CSS px,必须换算
    const PAD = 24 * z; // 让下一张卡露个边,暗示"还有更多"
    let delta = 0;
    if (left < PAD) delta = left - PAD;
    else if (left + r.width > viewR.width - PAD)
      delta = left + r.width - viewR.width + PAD;
    if (delta !== 0)
      track.style.transform = `translateX(${Math.min(0, cur - delta / z)}px)`;
    /* 继续往外层冒:让包着这一行的纵向列把整行滚进视野。 */
    outerNotify?.(node);
  };

  return (
    <FocusContext.Provider value={fk}>
      <ScrollNotify.Provider value={notify}>
        <div ref={ref}>
          <div ref={viewRef} className={`hscroll ${className}`.trim()}>
            <div ref={trackRef} className={trackClass}>
              {children}
            </div>
          </div>
        </div>
      </ScrollNotify.Provider>
    </FocusContext.Provider>
  );
}

/* ------------------------------------------------------------
   纵向页
   ------------------------------------------------------------ */

export function FocusColumn({
  children,
  className = "",
  focusKey,
  /** 顶部固定区高度(页标题不跟着滚)。 */
  topPad = 0,
}: {
  children: ReactNode;
  className?: string;
  focusKey?: string;
  topPad?: number;
}) {
  const innerRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<HTMLDivElement>(null);
  const outerNotify = useContext(ScrollNotify);

  const { ref, focusKey: fk } = useFocusable<object, HTMLDivElement>({
    focusKey,
    saveLastFocusedChild: true,
    trackChildren: true,
  });

  const notify = (node: HTMLElement) => {
    const inner = innerRef.current;
    const view = viewRef.current;
    if (!inner || !view) return;
    const viewR = view.getBoundingClientRect();
    const r = node.getBoundingClientRect();
    const top = r.top - viewR.top;
    const cur = readTranslate(inner, "Y");
    const z = zoomOf(view);
    const PAD = 40 * z; // 焦点行上下留呼吸位,否则光晕贴边被祖先 overflow 裁掉
    let delta = 0;
    if (top < topPad * z + PAD) delta = top - topPad * z - PAD;
    else if (top + r.height > viewR.height - PAD)
      delta = top + r.height - viewR.height + PAD;
    if (delta !== 0)
      inner.style.transform = `translateY(${Math.min(0, cur - delta / z)}px)`;
    /* 嵌套时(行在列里)继续往上冒 —— 否则横向行会滚,但那一整行不会被带进视野。 */
    outerNotify?.(node);
  };

  return (
    <FocusContext.Provider value={fk}>
      <ScrollNotify.Provider value={notify}>
        <div ref={ref} style={{ height: "100%" }}>
          <div
            ref={viewRef}
            className={`vscroll ${className}`.trim()}
            style={{ height: "100%" }}
          >
            <div ref={innerRef} className="inner">
              {children}
            </div>
          </div>
        </div>
      </ScrollNotify.Provider>
    </FocusContext.Provider>
  );
}

/* ------------------------------------------------------------
   焦点边界:面板 / 对话框打开时,焦点不许跑到底下的页面上
   ------------------------------------------------------------ */

/** ★ 只写 isFocusBoundary 不生效,必须同时套 FocusContext.Provider ——
 *  这是 norigin 最容易漏的一条,漏了的表现是「面板开着,按左却选中了背后的卡片」。 */
export function FocusBoundary({
  children,
  focusKey,
  className,
  style,
}: {
  children: ReactNode;
  focusKey?: string;
  className?: string;
  style?: React.CSSProperties;
}) {
  const { ref, focusKey: fk, focusSelf } = useFocusable<object, HTMLDivElement>({
    focusKey,
    isFocusBoundary: true,
    saveLastFocusedChild: true,
    trackChildren: true,
  });

  useEffect(() => {
    focusSelf();
  }, [focusSelf]);

  return (
    <FocusContext.Provider value={fk}>
      {/* 面板内部自带滚动,复用纵向列的通知机制 */}
      <div ref={ref} className={className} style={style}>
        {children}
      </div>
    </FocusContext.Provider>
  );
}

/* ---- 小工具 ---- */

function readTranslate(el: HTMLElement, axis: "X" | "Y"): number {
  const m = new RegExp(`translate${axis}\\((-?[\\d.]+)px\\)`).exec(el.style.transform);
  return m ? parseFloat(m[1]) : 0;
}

/** 当前 zoom 系数。

    ★ 这个换算不能省。`.tv-app` 用 zoom 把 1920 版式缩到实际屏幕,于是:
      - `getBoundingClientRect()` 返回的是**缩放后的设备 px**(1920 的元素量出来 1175)
      - `style.transform = translateY(Npx)` 里的 N 却是**未缩放的 CSS px**
      两者直接相减再赋值,滚动距离就只有该走的 61%,表现是
      「能滚,但焦点项永远差一点点露不全」—— 比完全不滚更难发现。

    库自己的方向判定不受影响:它全程用 gBCR,同一套坐标系里比大小,等比缩放不改变相对关系。
    只有**我们把测量结果写回 transform** 这一步需要换算回去。 */
function zoomOf(el: HTMLElement): number {
  const app = el.closest(".tv-app") as HTMLElement | null;
  const z = app ? parseFloat(getComputedStyle(app).zoom || "1") : 1;
  return Number.isFinite(z) && z > 0 ? z : 1;
}
