import { useEffect, useMemo, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { resolvePluginAssetUrl } from "@shared/api";
import { sanitizeTree, initialFormState, type PluginNode } from "@shared/plugin-ui";

/* ============================================================
   插件声明式 UI 渲染器。
   ------------------------------------------------------------
   插件交一棵 JSON 描述树,这里用**宿主自己的组件**画出来 ——
   所以插件界面自动跟深/浅色主题走,而插件永远碰不到宿主的 DOM。
   树的消毒(深度/节点数封顶、URL 协议白名单)在 @shared/plugin-ui,
   那一层可以用 node 直跑单测。

   表单状态由这里持有:按钮点下去时把整份表单一起交给 onAction,
   插件端只写一个 submit(values) 就够,不用自己管每个输入框。
   ============================================================ */

export type FormValues = Record<string, string | boolean>;

type Props = {
  /** 插件交上来的**原始**树(未消毒)。传 null / 非法值都只会渲染成空。 */
  raw: unknown;
  /** 点按钮或列表项时回调。handler = 插件 data 里的字段名。 */
  onAction?: (handler: string, values: FormValues, itemId?: string) => void;
  /** 正在跑的 handler 名(禁用按钮用)。 */
  busy?: string | null;
  /** 树为空时的占位文案。不给就什么都不画。 */
  empty?: string;
  /** 表单值变化时回调。给"提交按钮由宿主提供"的场景用(showForm 弹窗)。 */
  onValues?: (v: FormValues) => void;
};

export function Sw({
  on,
  onChange,
  disabled,
}: {
  on: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className={"sw" + (on ? " on" : "")}
      role="switch"
      aria-checked={on}
      disabled={disabled}
      style={disabled ? { opacity: 0.45 } : undefined}
      onClick={() => onChange(!on)}
    >
      <i />
    </button>
  );
}

export default function PluginView({ raw, onAction, busy, empty, onValues }: Props) {
  const tree = useMemo(() => sanitizeTree(raw), [raw]);
  const [values, setValues] = useState<FormValues>(() => initialFormState(tree));

  /* 插件推来新树时重置表单初值。**依赖是 tree 不是 raw** ——
     raw 每次 invoke 都是新对象引用,挂 raw 会让用户正在输入的框
     每次轮询刷新都被清空。 */
  useEffect(() => {
    const init = initialFormState(tree);
    setValues(init);
    onValues?.(init);
    // onValues 故意不进依赖:调用方一般传的是内联箭头函数,进了依赖就每帧重置表单。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tree]);

  if (!tree) {
    /* ★ 「插件交了东西、但一个节点都画不出来」和「插件什么都没交」是两回事,
       以前都画成一片空白。空白是这个系统里最贵的失败模式:插件作者看不出
       自己写错了什么,日志里也没有痕迹。最常见的两种写错都落在这条分支上 ——
       返回 `{metrics:[...]}` 这类旧形状(没有 t 字段),或者输入控件漏了 id。 */
    const gaveSomething = !!raw && typeof raw === "object";
    if (gaveSomething)
      return (
        <div className="pv-empty">
          这个插件返回的界面描述看不懂,一个节点都画不出来。
          <br />
          常见原因:根节点缺 <code>t</code> 字段(旧版插件的 <code>{"{metrics:[…]}"}</code> 形状),
          或者输入控件的键写成了 <code>key</code> 而不是 <code>id</code>。
        </div>
      );
    return empty ? <div className="pv-empty">{empty}</div> : null;
  }

  const set = (id: string, v: string | boolean) =>
    setValues((s) => {
      const next = { ...s, [id]: v };
      onValues?.(next);
      return next;
    });
  const fire = (handler: string | undefined, itemId?: string) => {
    if (handler && onAction) onAction(handler, values, itemId);
  };

  const render = (n: PluginNode, key: string): React.ReactNode => {
    switch (n.t) {
      case "text":
        return (
          <div key={key} className={"pv-text " + (n.variant ?? "body")}>
            {n.text}
          </div>
        );
      case "row":
        return (
          <div key={key} className={"pv-row" + (n.wrap ? " wrap" : "")}>
            {n.children.map((c, i) => render(c, `${key}.${i}`))}
          </div>
        );
      case "col":
        return (
          <div key={key} className="pv-col">
            {n.children.map((c, i) => render(c, `${key}.${i}`))}
          </div>
        );
      case "divider":
        return <div key={key} className="pv-div" />;
      case "badge":
        return (
          <span key={key} className={"pv-badge " + (n.tone ?? "info")}>
            {n.text}
          </span>
        );
      case "stat":
        return (
          <div key={key} className="pv-stat">
            <b>{n.value}</b>
            <span>{n.label}</span>
            {n.hint && <i>{n.hint}</i>}
          </div>
        );
      case "progress":
        return (
          <div key={key} className="pv-prog">
            {n.label && <span>{n.label}</span>}
            <div className="bar">
              <i style={{ width: `${Math.round(n.value * 100)}%` }} />
            </div>
          </div>
        );
      case "image":
        return (
          <img
            key={key}
            className="pv-img"
            /* 插件写的是 `lpplugin://<id>/<路径>`(文档也这么教)。那个字符串
               只在 Linux 上碰巧能用 —— Windows 的 WebView2 不认这个 scheme,
               直接是坏图且不报错。这里换成当前平台真取得到的 URL。 */
            src={resolvePluginAssetUrl(n.src)}
            alt={n.alt ?? ""}
            style={n.height ? { height: n.height } : undefined}
          />
        );
      case "link":
        // 外链一律丢给系统浏览器。在 WebView 里直接导航会把整个 app 顶掉
        // (单窗口 SPA,没有后退键回得来)。
        return (
          <button key={key} type="button" className="pv-link" onClick={() => openUrl(n.url)}>
            {n.text}
          </button>
        );
      case "button":
        return (
          <button
            key={key}
            type="button"
            className={
              "btn sm" + (n.variant === "primary" ? " primary" : n.variant === "danger" ? " danger" : "")
            }
            disabled={!!busy && busy === n.handler}
            onClick={() => fire(n.handler)}
          >
            {busy && busy === n.handler ? "…" : n.label}
          </button>
        );
      case "input":
        return (
          <label key={key} className="pv-field">
            {n.label && <span>{n.label}</span>}
            {n.multiline ? (
              <textarea
                className="field"
                rows={4}
                placeholder={n.placeholder}
                value={String(values[n.id] ?? "")}
                onChange={(e) => set(n.id, e.target.value)}
              />
            ) : (
              <input
                className="field"
                type={n.password ? "password" : "text"}
                placeholder={n.placeholder}
                value={String(values[n.id] ?? "")}
                onChange={(e) => set(n.id, e.target.value)}
              />
            )}
          </label>
        );
      case "select":
        return (
          <label key={key} className="pv-field">
            {n.label && <span>{n.label}</span>}
            <select
              className="field"
              value={String(values[n.id] ?? "")}
              onChange={(e) => set(n.id, e.target.value)}
            >
              {n.options.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
        );
      case "switch":
        return (
          <div key={key} className="pv-switch">
            <span>{n.label}</span>
            <Sw on={values[n.id] === true} onChange={(v) => set(n.id, v)} />
          </div>
        );
      case "list":
        return (
          <div key={key} className="pv-list">
            {n.items.map((it, i) => (
              <button
                key={it.id ?? i}
                type="button"
                className="pv-li"
                disabled={!it.handler}
                onClick={() => fire(it.handler, it.id)}
              >
                <b>{it.title}</b>
                {it.subtitle && <span>{it.subtitle}</span>}
              </button>
            ))}
          </div>
        );
    }
  };

  return <div className="pv">{render(tree, "r")}</div>;
}
