# ui/ —— 各端界面

每端一个目录，各写各的交互语言；业务逻辑不在这里，在 `crates/core`（Rust），
经 Tauri 命令桥暴露给前端。

| 目录 | 状态 | 说明 |
|------|------|------|
| `shared/` | 在用 | 各端共用层：`api.ts`（Tauri invoke 桥 + 类型）、`theme.ts`、`tokens.css` |
| `desktop/` | 在用 | Windows / Linux 桌面 UI，宿主是 `apps/desktop` |
| `mobile/` | 待建 | Android 手机 UI |
| `tv/` | 待建 | Android TV UI（10-foot 版式，遥控焦点） |

## 引用 shared

用别名，不要写相对路径：

```ts
import { listFavorites } from "@shared/api";
import "@shared/tokens.css";
```

各端目录深度不一样，相对路径会在每个端各写一套。别名定义在两个地方，
**必须同步**——只改一边的话 vite 构建是绿的、`tsc` 直接红，而 `npm run build`
是 `tsc && vite build`：

- `vite.config.ts` → `resolve.alias`
- `tsconfig.json` → `compilerOptions.paths`

## 往 shared 里放什么

只放**任何端都成立**的东西：与后端通信的桥、跨端一致的设计 token、纯逻辑函数。
布局、组件、页面一律留在各端自己的目录里——TV 的焦点导航和手机的手势
没有共用的可能，硬提取只会造出一个到处 `if (isTv)` 的抽象。
