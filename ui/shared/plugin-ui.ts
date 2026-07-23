/* ============================================================
   插件声明式 UI —— 描述树的类型 + 消毒。
   ------------------------------------------------------------
   插件交一棵 JSON 树,宿主用**自己的组件**渲染。好处有两条:
   自动跟主题(深/浅色、TV 放大)走;插件永远拿不到宿主的 DOM 和
   `__TAURI_INTERNALS__.invoke`(拿到了整套权限模型就是摆设)。

   放不下的 10% 走 sandboxViews 逃生舱(独立 origin 的 iframe,
   经 `lpplugin://` 供文件)。

   ★ 这棵树是**插件写的、不可信的数据**,不是我们自己的组件 props。
     渲染前必须过 sanitizeTree:
       - 深度/节点数封顶 —— 否则一棵递归树能把渲染栈打爆(白屏,
         而窗口是透明的,看起来就是「整个 app 打不开」)
       - link/image 的 URL 走协议白名单 —— `javascript:` 是现成的 XSS
   ============================================================ */

export type Tone = "info" | "good" | "warn" | "danger";

export type PluginNode =
  | { t: "text"; text: string; variant?: "title" | "body" | "hint" | "mono" }
  | { t: "row"; children: PluginNode[]; wrap?: boolean }
  | { t: "col"; children: PluginNode[] }
  | { t: "divider" }
  | { t: "badge"; text: string; tone?: Tone }
  | { t: "stat"; label: string; value: string; hint?: string }
  | { t: "progress"; value: number; label?: string }
  | { t: "image"; src: string; alt?: string; height?: number }
  | { t: "link"; text: string; url: string }
  | { t: "button"; label: string; handler?: string; variant?: "primary" | "normal" | "danger" }
  | { t: "input"; id: string; label?: string; placeholder?: string; value?: string; password?: boolean; multiline?: boolean }
  | { t: "select"; id: string; label?: string; value?: string; options: { value: string; label: string }[] }
  | { t: "switch"; id: string; label: string; value?: boolean }
  | { t: "list"; items: { id?: string; title: string; subtitle?: string; handler?: string }[] };

/** 一棵树最多这么深。超出的子树整棵丢掉(不是截断成半棵)。 */
export const MAX_DEPTH = 12;
/** 一棵树最多这么多节点。 */
export const MAX_NODES = 400;
/** 单个容器最多这么多子节点。 */
export const MAX_CHILDREN = 100;

const IMAGE_SCHEMES = ["data:image/", "lpplugin://", "https://"];
const LINK_SCHEMES = ["https://", "http://"];

const str = (v: unknown, max = 2000): string =>
  typeof v === "string" ? v.slice(0, max) : "";
const num = (v: unknown, dflt = 0): number =>
  typeof v === "number" && Number.isFinite(v) ? v : dflt;
const oneOf = <T extends string>(v: unknown, allowed: readonly T[]): T | undefined =>
  typeof v === "string" && (allowed as readonly string[]).includes(v) ? (v as T) : undefined;

const schemeOk = (url: string, allowed: string[]) => {
  const u = url.trim().toLowerCase();
  return allowed.some((s) => u.startsWith(s));
};

/**
 * 把插件交上来的任意 JSON 消毒成一棵可渲染的树。
 *
 * 返回 null = 整棵树不可渲染(空/全是非法节点)。宁可什么都不显示,
 * 也不要把一半的东西画出来让用户以为插件坏了一半。
 */
export function sanitizeTree(raw: unknown): PluginNode | null {
  const budget = { left: MAX_NODES };
  return sanitize(raw, 0, budget);
}

function sanitize(raw: unknown, depth: number, budget: { left: number }): PluginNode | null {
  if (depth >= MAX_DEPTH || budget.left <= 0) return null;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  budget.left -= 1;

  switch (o.t) {
    case "text": {
      const text = str(o.text);
      if (!text) return null;
      return { t: "text", text, variant: oneOf(o.variant, ["title", "body", "hint", "mono"] as const) };
    }
    case "row":
    case "col": {
      const kids = kidsOf(o.children, depth, budget);
      // 空容器留着只会画出一条莫名其妙的空隙。
      if (!kids.length) return null;
      return o.t === "row"
        ? { t: "row", children: kids, wrap: o.wrap === true }
        : { t: "col", children: kids };
    }
    case "divider":
      return { t: "divider" };
    case "badge": {
      const text = str(o.text, 60);
      return text ? { t: "badge", text, tone: oneOf(o.tone, ["info", "good", "warn", "danger"] as const) } : null;
    }
    case "stat": {
      const label = str(o.label, 60);
      const value = str(o.value, 60);
      if (!label && !value) return null;
      return { t: "stat", label, value, hint: str(o.hint, 120) || undefined };
    }
    case "progress": {
      // 0..1。越界的值 clamp 而不是丢 —— 进度条画歪了不致命,不画反而让人以为卡死。
      const v = Math.max(0, Math.min(1, num(o.value)));
      return { t: "progress", value: v, label: str(o.label, 120) || undefined };
    }
    case "image": {
      const src = str(o.src, 4_000_000); // data URI 可能很长
      // 任意 https 图片会把用户 IP 透给插件作者指定的第三方,但禁掉又没法用远程图 ——
      // 折中:允许 https,不允许 http(明文)和其它协议。
      if (!src || !schemeOk(src, IMAGE_SCHEMES)) return null;
      return { t: "image", src, alt: str(o.alt, 200) || undefined, height: o.height === undefined ? undefined : Math.max(16, Math.min(400, num(o.height, 120))) };
    }
    case "link": {
      const url = str(o.url, 2000);
      const text = str(o.text, 200);
      // `javascript:` / `data:` 都是现成的注入面。
      if (!url || !text || !schemeOk(url, LINK_SCHEMES)) return null;
      return { t: "link", text, url };
    }
    case "button": {
      const label = str(o.label, 60);
      if (!label) return null;
      return {
        t: "button",
        label,
        handler: str(o.handler, 120) || undefined,
        variant: oneOf(o.variant, ["primary", "normal", "danger"] as const),
      };
    }
    case "input": {
      const id = str(o.id, 120);
      if (!id) return null;
      return {
        t: "input", id,
        label: str(o.label, 120) || undefined,
        placeholder: str(o.placeholder, 200) || undefined,
        value: str(o.value, 8000),
        password: o.password === true,
        multiline: o.multiline === true,
      };
    }
    case "select": {
      const id = str(o.id, 120);
      const optsRaw = Array.isArray(o.options) ? o.options.slice(0, MAX_CHILDREN) : [];
      const options = optsRaw
        .map((x) => {
          if (!x || typeof x !== "object") return null;
          const r = x as Record<string, unknown>;
          const value = str(r.value, 200);
          if (!value) return null;
          return { value, label: str(r.label, 200) || value };
        })
        .filter((x): x is { value: string; label: string } => x !== null);
      if (!id || !options.length) return null;
      return { t: "select", id, label: str(o.label, 120) || undefined, value: str(o.value, 200), options };
    }
    case "switch": {
      const id = str(o.id, 120);
      const label = str(o.label, 200);
      if (!id || !label) return null;
      return { t: "switch", id, label, value: o.value === true };
    }
    case "list": {
      const rows = Array.isArray(o.items) ? o.items.slice(0, MAX_CHILDREN) : [];
      const items = rows
        .map((x) => {
          if (!x || typeof x !== "object") return null;
          const r = x as Record<string, unknown>;
          const title = str(r.title, 300);
          if (!title) return null;
          budget.left -= 1;
          return {
            id: str(r.id, 120) || undefined,
            title,
            subtitle: str(r.subtitle, 500) || undefined,
            handler: str(r.handler, 120) || undefined,
          };
        })
        .filter((x): x is NonNullable<typeof x> => x !== null);
      return items.length ? { t: "list", items } : null;
    }
    default:
      // 不认识的节点直接丢。将来加了新块,老版本宿主上就是「少了一块」而不是崩。
      return null;
  }
}

function kidsOf(raw: unknown, depth: number, budget: { left: number }): PluginNode[] {
  if (!Array.isArray(raw)) return [];
  const out: PluginNode[] = [];
  for (const c of raw.slice(0, MAX_CHILDREN)) {
    if (budget.left <= 0) break;
    const n = sanitize(c, depth + 1, budget);
    if (n) out.push(n);
  }
  return out;
}

/** 收集树里所有表单控件的初始值,给渲染器当 state 种子。 */
export function initialFormState(node: PluginNode | null): Record<string, string | boolean> {
  const out: Record<string, string | boolean> = {};
  const walk = (n: PluginNode) => {
    switch (n.t) {
      case "input":
        out[n.id] = n.value ?? "";
        break;
      case "select":
        out[n.id] = n.value || n.options[0]?.value || "";
        break;
      case "switch":
        out[n.id] = n.value === true;
        break;
      case "row":
      case "col":
        n.children.forEach(walk);
        break;
    }
  };
  if (node) walk(node);
  return out;
}
