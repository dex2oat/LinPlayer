# ui/tv —— Android TV UI

10-foot 版式 + 遥控焦点。宿主是 `apps/android`(**待建**),入口 `index-tv.html`。

## 先读这个:草稿是规格,不是参考图

`docs/tv-drafts.html`(22 屏,不入库)**每一屏都按真实 1920×1080 dp 绘制**。
稿子里量到的数字就是代码里的数字,`theme/tv.css` 是那份稿子的直接抬升。

**改版式的顺序是:先改草稿 → 评审 → 再抬到 tv.css。** 反过来做,两边立刻对不上,
而"草稿和实现哪个算数"这个问题一旦出现就再也说不清了。

## 硬约束(违反了会出的是焦点 bug,不是审美问题)

| 约束 | 为什么 |
|---|---|
| 焦点库 `@noriginmedia/norigin-spatial-navigation`,配置只在 `app/focus.ts` 改 | 各页各配 = 各页各的焦点行为 |
| `layoutAdapter: GetBoundingClientRectAdapter` **必开** | 默认适配器读不到 CSS transform 和 zoom,我们两样都用。不开的表现是"右边明明有卡,按右却跳到下一行",**静态稿上完全看不出来** |
| 一切可聚焦元素走 `components/Focus.tsx` 的 `FocusItem` | 「焦点移出可视区要滚过去」每个列表都要做,散着写必有页面忘记,忘记的表现是**焦点看不见了但按键还在生效** |
| 面板/对话框用 `FocusBoundary` | 只写 `isFocusBoundary` 不生效,必须同时套 `FocusContext.Provider`。漏了的表现是"面板开着,按左却选中了背后的卡片" |
| 禁 `backdrop-filter` / 大 blur / 动画 `box-shadow` | 机顶盒 WebView 很弱。PC 端也栽过 |
| 只动 `transform` 和 `opacity` | 其余属性一律触发重排/重绘 |
| hover 样式必须包 `@media (hover:hover)` | WebView 在 D-pad 移动时会误报 hover |
| 强制深色,**不 import `@shared/tokens.css`** | 那份 token 带浅色分支和桌面专属量;浅色主题在客厅是灾难 |
| 不自建虚拟键盘 | Android TV 有系统输入法(Leanback IME),白拿语音输入和外接键盘。但**它会盖住下半屏**,要输入的内容必须排在上半屏 |

## 两条必须由壳提供的通道

**`apps/android` 的 Activity 里不预留,整个 TV 端后期改不动:**

- `KEYCODE_BACK` 会被 Activity 自己吃掉,WebView 收不到 → 返回键全站失灵
- 媒体键(播放/暂停/上一集/下一集)同理

壳侧做法(`onKeyDown` 里,并 `return true` 吃掉该键):

```java
webView.evaluateJavascript("window.__lpTvKey && window.__lpTvKey('back')", null);
```

前端侧 `app/focus.ts` 的 `installTvKeyBridge()` 已经把入口装好,页面用 `onTvKey()` 订阅。
桌面/浏览器里没有壳,同一个函数用 Esc/Backspace 兜底 —— TV UI 目前就是靠这条在 PC 上开发的。

## 版式口径(逐条都是用户在草稿评审里纠正过的)

- **10-foot ≠ 什么都放大**。1920 屏在 3 米外的视角大小和笔记本在臂展距离差不多。
  要放大的只是「必须读的字」。**Hero / 详情页上封面才是主角,控件让位** ——
  标题 36–40sp、按钮 52dp/17sp、信息块最宽 600dp。做大只会把封面糊死。
- **不用渐变,只有两种状态**。压在画面/封面上的东西**要么全透明,要么不透明块**。
  全屏渐变每帧都要重新合成,且渐变边界远看是糊的。
  裸文字(播放页标题、时间)失去渐变兜底会糊在亮场景上 → 给它**自带不透明底**,
  **不是加回渐变**。
- **TV 的交互密度不能照搬 PC**。鼠标点击代价与距离无关,遥控器代价 = **焦点格数**。
  横排 6 个筛选 chip 在 PC 免费,在 TV 是 5 次方向键 → 改成单入口 + 右侧面板。
- **「线路」只出现在线路管理页**。媒体库标题下、播放页副标题、服务器卡片一律不显示线路或 URL。
  详情页的版本面板选的是 **MediaSource(版本)**,不是线路 —— 两个概念别混。
- **服务器卡片只显示 图标 / 名称 / 备注**三样。名字下面那行小字是**备注**,不是域名。
- **模式 ≠ 新页面**。排序模式与服务器页共用同一张卡、同一栅格、同一间距,只叠虚线框 + 提示带。
- **图标按钮必须带文字**。裸图标方块用户第一反应是"那是什么"。
  播放控制左组(上一集/快退/播放/快进/下一集)是通用约定可纯图标,
  右组(字幕/音轨/弹幕/更多)必须图标+文字。

## 源范围

**只做四种源:Emby / 飞牛影视 / 网盘 / OpenList。不做 Ani-RSS 订阅** ——
要填 RSS 地址和正则,遥控器上是灾难,留给手机和 PC 端。

**版本行只聚合 Emby**:网盘/OpenList/飞牛没有 MediaSource 这个概念,
要聚合就得逐个探测文件是否存在,为一行选择器做这件事不划算。

## 目录

| 路径 | 内容 |
|---|---|
| `main.tsx` | 入口。**焦点库和壳键桥必须在任何组件挂载前装好** |
| `App.tsx` | 路由(一个栈,不上路由库)+ 会话门 |
| `app/focus.ts` | 焦点库初始化 / 壳键契约 / 1920 基准缩放 |
| `app/icons.tsx` | 36 个图标,**由草稿的 `<symbol>` 原样搬运**,不是重画的 |
| `app/nav.ts` `app/Rail.tsx` | 导航轨 |
| `components/Focus.tsx` | `FocusItem` / `FocusRow` / `FocusColumn` / `FocusBoundary` |
| `theme/tv.css` | 全站样式。**页面不要新写 CSS 文件** |

## 缩放:用 zoom 不用 transform:scale

版式按 1920×1080 写死,`applyTvScale()` 给 `.tv-app` 设 `zoom`。

★ **不能用 `transform: scale()`** —— transform 会让元素成为后代 `position:fixed` 的
**包含块**,整棵树的 fixed 都会以它为参照而不是视口。PC 端的右键菜单/toast 偏位就是栽在这。
`zoom` 只影响布局尺寸,不建立包含块,且 `getBoundingClientRect` 返回缩放后的真实坐标,
与焦点库的测量适配器天然一致。

## 现状

后端桥 `@shared/api` 已完整(225 个命令)。**但那 225 个命令全部注册在
`apps/desktop/src/lib.rs`** —— 一个桌面专属文件。`crates/core` 是故意不依赖 tauri 的
(为了交叉编译安卓),所以 `apps/android` 建起来之前,TV UI 在真机上一个命令都调不到。

因此当前的开发/验证路径是:**跑桌面 Tauri 壳,让它加载 `index-tv.html`**,
拿到的是真实 Emby 数据和真实 mpv 播放器。
