import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { listen } from "@tauri-apps/api/event";
import { pluginInvokeField, pluginPanels, pluginUiRespond, type PluginPanel } from "@shared/api";
import PluginView, { type FormValues } from "./PluginView";

/* ============================================================
   插件在宿主界面里露头的两条通道。
   ------------------------------------------------------------
   ① <PluginUiHost/>  —— 插件主动弹的东西(toast/对话框/表单/列表/进度)。
      核层把 `ctx.ui.*` 发成 `plugin://ui-request` 事件;需要返回值的那几个
      在 Rust 侧挂着 oneshot 等前端 `plugin_ui_respond` 回填 ——
      **这里不回,插件那边就永远悬着**(JS 侧的 await 不会超时)。
      所以每条需要返回值的请求都必须有出口:关掉 = 回 null,不是不回。

   ② <PluginSlot slot="…"/> —— 插件挂在固定位置的面板(首页/侧栏/设置/播放器)。
      面板初始内容靠调它的 handler 拿;之后插件可以用 ctx.ui.render 主动推新树。

   插件推来的树都是**不可信数据**,渲染前一律过 sanitizeTree(在 PluginView 里)。
   ============================================================ */

/* ---------- ctx.ui.render 推送的树 ---------- */

const rendered = new Map<string, unknown>();
const subs = new Set<() => void>();
const notify = () => subs.forEach((f) => f());

function subscribe(f: () => void) {
  subs.add(f);
  return () => void subs.delete(f);
}

/** 订阅某个视图最新被推送的树。没推过就是 undefined。 */
function useRendered(key: string): unknown {
  return useSyncExternalStore(
    subscribe,
    () => rendered.get(key),
    () => undefined,
  );
}

/* ---------- 需要返回值的 UI 请求 ---------- */

type Pending =
  | { id: number; kind: "dialog"; title: string; message: string; okText: string; cancelText: string }
  | { id: number; kind: "form"; title: string; description: string; tree: unknown; submitText: string }
  | { id: number; kind: "list"; title: string; tree: unknown };

/** `ctx.ui.showForm({fields:[…]})` 是 render 的糖 —— 折成同一棵描述树,
 *  这样表单控件的样式/主题只有一套实现。 */
function formTree(args: Record<string, unknown>): unknown {
  const fields = Array.isArray(args.fields) ? args.fields : [];
  return {
    t: "col",
    children: fields.map((f) => {
      const o = (f ?? {}) as Record<string, unknown>;
      const type = String(o.type ?? "text");
      if (type === "switch" || type === "bool")
        return { t: "switch", id: o.id, label: o.label ?? o.id, value: o.value };
      if (type === "select")
        return { t: "select", id: o.id, label: o.label, value: o.value, options: o.options };
      return {
        t: "input",
        id: o.id,
        label: o.label,
        placeholder: o.placeholder,
        value: o.value,
        password: type === "password",
        multiline: type === "textarea",
      };
    }),
  };
}

function listTree(args: Record<string, unknown>): unknown {
  const items = Array.isArray(args.items) ? args.items : [];
  return {
    t: "list",
    items: items.map((it) => {
      const o = (it ?? {}) as Record<string, unknown>;
      return { id: String(o.id ?? o.value ?? o.title ?? ""), title: o.title ?? o.label, subtitle: o.subtitle, handler: "pick" };
    }),
  };
}

export function PluginUiHost() {
  const [toast, setToast] = useState<string | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [progress, setProgress] = useState<{ title: string; value: number } | null>(null);
  const toastTimer = useRef<number | null>(null);

  const flash = useCallback((text: string) => {
    setToast(text);
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    toastTimer.current = window.setTimeout(() => setToast(null), 3600);
  }, []);

  useEffect(() => {
    const un = listen<{
      id: number;
      pluginId: string;
      method: string;
      args: unknown[];
    }>("plugin://ui-request", (e) => {
      const { id, pluginId, method, args } = e.payload;
      const a0 = (args?.[0] ?? {}) as Record<string, unknown>;
      switch (method) {
        case "showToast":
          flash(String(a0.message ?? args?.[0] ?? ""));
          break;
        case "render":
          // ctx.ui.render(viewId, tree)
          rendered.set(`${pluginId}/${String(args?.[0] ?? "")}`, args?.[1]);
          notify();
          break;
        case "showProgress":
          setProgress({ title: String(a0.title ?? "处理中"), value: 0 });
          pluginUiRespond(id, { handle: id });
          break;
        case "updateProgress":
          setProgress((p) =>
            p ? { ...p, value: Math.max(0, Math.min(1, Number(a0.value ?? args?.[1] ?? 0))) } : p,
          );
          break;
        case "closeProgress":
          setProgress(null);
          break;
        case "showDialog":
          setPending({
            id, kind: "dialog",
            title: String(a0.title ?? "提示"),
            message: String(a0.message ?? ""),
            okText: String(a0.confirmLabel ?? "确定"),
            cancelText: String(a0.cancelLabel ?? "取消"),
          });
          break;
        case "showForm":
          setPending({
            id, kind: "form",
            title: String(a0.title ?? "请填写"),
            description: String(a0.description ?? ""),
            tree: formTree(a0),
            submitText: String(a0.submitLabel ?? "确定"),
          });
          break;
        case "showList":
          setPending({ id, kind: "list", title: String(a0.title ?? "请选择"), tree: listTree(a0) });
          break;
        case "openPage":
          // v2 没有"插件独立页面"这个概念(面板挂 slot、复杂界面走沙箱视图),
          // 静默吞掉会让插件作者以为自己写错了,如实说一声。
          flash("这个插件想打开一个独立页面,当前版本不支持");
          break;
        default:
          break;
      }
    });
    return () => void un.then((f) => f());
  }, [flash]);

  /** 关掉 = 回 null。**必须回** —— 不回的话插件那边的 await 永远悬着。 */
  const close = (value: unknown) => {
    if (pending) pluginUiRespond(pending.id, value).catch(() => {});
    setPending(null);
  };

  return (
    <>
      {toast && <div className="pg-toast">{toast}</div>}

      {progress && (
        <div className="pg-scrim center">
          <div className="pg-modal" style={{ maxWidth: 380 }}>
            <h4>{progress.title}</h4>
            <div className="pv-prog">
              <div className="bar">
                <i style={{ width: `${Math.round(progress.value * 100)}%` }} />
              </div>
            </div>
          </div>
        </div>
      )}

      {pending && (
        <div className="pg-scrim center" onClick={() => close(null)}>
          <div className="pg-modal" onClick={(e) => e.stopPropagation()}>
            <h4>{pending.kind === "dialog" ? pending.title : pending.title}</h4>
            {pending.kind === "dialog" ? (
              <>
                <p className="pg-desc">{pending.message}</p>
                <div className="ft">
                  <button type="button" className="btn" onClick={() => close(false)}>
                    {pending.cancelText}
                  </button>
                  <button type="button" className="btn primary" onClick={() => close(true)}>
                    {pending.okText}
                  </button>
                </div>
              </>
            ) : pending.kind === "form" ? (
              <FormModal
                description={pending.description}
                tree={pending.tree}
                submitText={pending.submitText}
                onCancel={() => close(null)}
                onSubmit={(v) => close(v)}
              />
            ) : (
              <div className="scroll">
                <PluginView raw={pending.tree} onAction={(_h, _v, itemId) => close(itemId ?? null)} />
              </div>
            )}
          </div>
        </div>
      )}
    </>
  );
}

function FormModal({
  description, tree, submitText, onCancel, onSubmit,
}: {
  description: string;
  tree: unknown;
  submitText: string;
  onCancel: () => void;
  onSubmit: (v: FormValues) => void;
}) {
  /* 提交按钮**不画进描述树里** —— 树是插件写的,把提交塞进去意味着
     插件忘了写按钮就是一个关不掉的弹窗。按钮由宿主固定提供,
     值靠 onValues 同步过来(不去扒 DOM)。 */
  const [values, setValues] = useState<FormValues>({});
  return (
    <>
      {description && <p className="hint">{description}</p>}
      <div className="scroll">
        <PluginView raw={tree} onValues={setValues} onAction={(_h, v) => onSubmit(v)} />
      </div>
      <div className="ft">
        <button type="button" className="btn" onClick={onCancel}>取消</button>
        <button type="button" className="btn primary" onClick={() => onSubmit(values)}>
          {submitText}
        </button>
      </div>
    </>
  );
}

/* ---------- 面板槽位 ---------- */

type SlotProps = {
  slot: string;
  /** 槽位标题。有插件挂上来才画,没有就整块不出现。 */
  title?: string;
  className?: string;
  /** 只画这个插件贡献的面板(插件详情页里的「设置」标签用)。 */
  onlyPlugin?: string;
};

/**
 * 把挂在某个 slot 上的插件面板画出来。
 *
 * 没有插件挂上来时**什么都不渲染**(连标题都不画)—— 一个空的
 * 「插件面板」标题栏比没有更糟。
 */
export function PluginSlot({ slot, title, className, onlyPlugin }: SlotProps) {
  const [panels, setPanels] = useState<PluginPanel[]>([]);

  const load = useCallback(() => {
    pluginPanels(slot)
      .then((ps) => setPanels(onlyPlugin ? ps.filter((p) => p.pluginId === onlyPlugin) : ps))
      .catch(() => setPanels([]));
  }, [slot, onlyPlugin]);

  useEffect(() => {
    load();
    // 启用/停用插件、插件自己注册新面板,都会发这个事件。
    const un = listen("plugin://extensions-changed", load);
    return () => void un.then((f) => f());
  }, [load]);

  if (panels.length === 0) return null;
  return (
    <div className={className}>
      {title && <div className="rowlab"><span className="h">{title}</span></div>}
      {panels.map((p) => (
        <PanelBody key={`${p.pluginId}/${p.id}`} panel={p} />
      ))}
    </div>
  );
}

function PanelBody({ panel }: { panel: PluginPanel }) {
  const key = `${panel.pluginId}/${panel.id}`;
  const pushed = useRendered(key);
  const [pulled, setPulled] = useState<unknown>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const handler = String(panel.data?.handler ?? "render");

  const pull = useCallback(() => {
    pluginInvokeField(panel.pluginId, "panels", panel.id, handler)
      .then(setPulled)
      .catch(() => setPulled(null));
  }, [panel.pluginId, panel.id, handler]);

  useEffect(() => { pull(); }, [pull]);

  /* 插件主动推的树优先于我们拉的那一棵 —— 推送是"最新",拉取只是"初始"。 */
  const tree = pushed ?? pulled;

  /* 点完之后必须让面板重新出数。
     ★ 第一版是「handler 返回了树才更新,返回 null 就什么都不做」——
     而绝大多数 handler 都只是干件事然后返回 null(改个开关、发个请求),
     于是**点了完全没反应**:插件作者被迫每个 handler 都手工拼一棵完整的树回来。
     现在:返回树就用它,没返回就自己再拉一次 render。 */
  const onAction = (h: string, values: FormValues, itemId?: string) => {
    setBusy(h);
    pluginInvokeField(panel.pluginId, "panels", panel.id, h, [{ ...values, itemId }])
      .then((r) => (r == null ? pull() : setPulled(r)))
      .catch(() => {})
      .finally(() => setBusy(null));
  };

  const title = String(panel.data?.title ?? "");
  return (
    <div className="pg-panel">
      {title && <div className="pv-text title">{title}</div>}
      <PluginView raw={tree} onAction={onAction} busy={busy} />
    </div>
  );
}
