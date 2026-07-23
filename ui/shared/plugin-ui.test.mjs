/* 插件 UI 描述树消毒自检。跑法:
     npx tsx ui/shared/plugin-ui.test.mjs
   这棵树是**插件写的、不可信的数据**,下面每条断言都对应一个真实攻击/崩溃面。 */
import assert from "node:assert/strict";
import { sanitizeTree, initialFormState, MAX_DEPTH, MAX_NODES } from "./plugin-ui.ts";

// ---- 正常树原样通过 ----
const ok = sanitizeTree({
  t: "col",
  children: [
    { t: "text", text: "标题", variant: "title" },
    { t: "stat", label: "今日流量", value: "1.2 GB" },
    { t: "row", children: [{ t: "button", label: "刷新", handler: "refresh", variant: "primary" }] },
  ],
});
assert.equal(ok.t, "col");
assert.equal(ok.children.length, 3);
assert.equal(ok.children[0].variant, "title");
assert.equal(ok.children[2].children[0].handler, "refresh");

const depthOf = (n) => (n && n.children ? 1 + Math.max(...n.children.map(depthOf)) : 1);
const countOf = (n) => (n && n.children ? 1 + n.children.reduce((a, c) => a + countOf(c), 0) : 1);

/* ★ 这两个炸弹测试第一版是**假绿**:炸弹被削成 null 时 depthOf(null)===1,
   两条断言就都轻松通过 —— 深度封顶和节点预算各自删掉一个,测试照样绿
   (只有两个一起删才会栈溢出翻红)。
   现在每一层都插一个兄弟节点,截断处的容器不会变空、不会 null 冒泡到根,
   于是量出来的是**真实的截断深度/节点数**;再加一条 `!== null` 把
   「整棵被清零」这种平凡通过排除掉。 */

// ---- 深度炸弹:一棵自嵌套 5000 层的树不能把渲染栈打爆 ----
// (窗口是透明的 —— 渲染抛错的观感是「整个 app 打不开」,见 [transparent-window-crash-looks-like-blackscreen])
let bomb = { t: "text", text: "底" };
for (let i = 0; i < 5000; i++) bomb = { t: "col", children: [{ t: "text", text: "层" }, bomb] };
const trimmed = sanitizeTree(bomb);
assert.notEqual(trimmed, null, "截断不该把整棵树清零");
assert.ok(depthOf(trimmed) <= MAX_DEPTH, `深度没封顶: ${depthOf(trimmed)}`);

// ---- 节点数炸弹 ----
// 单个容器铺 10 万个子节点只会撞上 MAX_CHILDREN,量不到预算;
// 要 50 个容器 × 50 行才让总数(2500)越过 MAX_NODES。
const wide = sanitizeTree({
  t: "col",
  children: Array.from({ length: 50 }, () => ({
    t: "col",
    children: Array.from({ length: 50 }, (_, i) => ({ t: "text", text: `第 ${i} 行` })),
  })),
});
assert.notEqual(wide, null);
assert.ok(countOf(wide) <= MAX_NODES, `节点数没封顶: ${countOf(wide)}`);

// 单容器宽度另算一条,免得两个上限互相打掩护。
const fat = sanitizeTree({
  t: "col",
  children: Array.from({ length: 100000 }, (_, i) => ({ t: "text", text: `第 ${i} 行` })),
});
assert.ok(fat.children.length <= 100, `单容器子节点没封顶: ${fat.children.length}`);

// ---- javascript: 链接必须整条丢掉,不是"渲染成不可点" ----
assert.equal(sanitizeTree({ t: "link", text: "点我", url: "javascript:alert(1)" }), null);
assert.equal(sanitizeTree({ t: "link", text: "点我", url: "JavaScript:alert(1)" }), null, "大小写绕过");
assert.equal(sanitizeTree({ t: "link", text: "点我", url: "data:text/html,<script>x</script>" }), null);
assert.equal(sanitizeTree({ t: "link", text: "点我", url: "file:///C:/Windows" }), null);
assert.equal(sanitizeTree({ t: "link", text: "官网", url: "https://example.com" }).url, "https://example.com");

// ---- 图片源:只认 data:image / lpplugin:// / https ----
assert.equal(sanitizeTree({ t: "image", src: "javascript:x" }), null);
assert.equal(sanitizeTree({ t: "image", src: "data:text/html;base64,AAAA" }), null, "data: 但不是图片");
assert.equal(sanitizeTree({ t: "image", src: "http://example.com/a.png" }), null, "明文 http 不认");
assert.ok(sanitizeTree({ t: "image", src: "data:image/png;base64,AAAA" }));
assert.ok(sanitizeTree({ t: "image", src: "lpplugin://com.x.y/logo.svg" }));

// ---- 不认识的节点丢掉,不炸 ----
const mixed = sanitizeTree({
  t: "col",
  children: [{ t: "未来的新块" }, { t: "text", text: "还在" }, null, 42, "字符串", { t: "text" }],
});
assert.equal(mixed.children.length, 1, "只该剩下那个合法的 text");
assert.equal(mixed.children[0].text, "还在");

// ---- 空容器不留下一条空隙 ----
assert.equal(sanitizeTree({ t: "col", children: [] }), null);
assert.equal(sanitizeTree({ t: "row", children: [{ t: "垃圾" }] }), null);

// ---- 非对象输入 ----
for (const junk of [null, undefined, 42, "text", [], true]) {
  assert.equal(sanitizeTree(junk), null, `${JSON.stringify(junk)} 该被拒`);
}

// ---- progress clamp 而不是丢(画歪不致命,不画会让人以为卡死) ----
assert.equal(sanitizeTree({ t: "progress", value: 5 }).value, 1);
assert.equal(sanitizeTree({ t: "progress", value: -3 }).value, 0);
assert.equal(sanitizeTree({ t: "progress", value: NaN }).value, 0);

// ---- select 至少要有一个合法选项,否则是个点不动的空控件 ----
assert.equal(sanitizeTree({ t: "select", id: "a", options: [] }), null);
assert.equal(sanitizeTree({ t: "select", id: "", options: [{ value: "x" }] }), null);
const sel = sanitizeTree({ t: "select", id: "q", options: [{ value: "hd" }, { value: "sd", label: "标清" }] });
assert.deepEqual(sel.options, [
  { value: "hd", label: "hd" },
  { value: "sd", label: "标清" },
]);

// ---- 表单初值 ----
const form = sanitizeTree({
  t: "col",
  children: [
    { t: "input", id: "token", value: "abc" },
    { t: "input", id: "chat" },
    { t: "switch", id: "on", label: "开启", value: true },
    { t: "select", id: "q", options: [{ value: "hd" }, { value: "sd" }] },
  ],
});
assert.deepEqual(initialFormState(form), { token: "abc", chat: "", on: true, q: "hd" });
assert.deepEqual(initialFormState(null), {});

// 没标签的开关是个「不知道自己在开什么」的裸开关 —— 整条丢掉才对。
assert.equal(sanitizeTree({ t: "switch", id: "on", value: true }), null);

console.log("plugin-ui: 全部通过");
