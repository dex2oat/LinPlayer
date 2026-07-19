# 开发与技术

> 仓库结构、本地开发与构建、技术栈。主文档见 [README](../README.md)。

## 技术栈

| 层 | 用什么 | 为什么 |
|:--|:--|:--|
| 业务核心 | [Rust](https://www.rust-lang.org/) + [Tokio](https://tokio.rs) + [reqwest](https://github.com/seanmonstar/reqwest)（rustls） | 一份代码各端共用；rustls 而非 native-tls，是为了去掉 openssl-sys，安卓交叉编译免装 OpenSSL |
| 桌面壳 | [Tauri 2](https://tauri.app) | 窗口 / IPC / 打包；前端用系统 WebView，不捆浏览器 |
| UI | [React 19](https://react.dev) + [TypeScript](https://www.typescriptlang.org) + [Vite](https://vite.dev) | 每端一套 UI，共用 `ui/shared` 的 API 桥与设计 token |
| 播放 | [libmpv](https://github.com/mpv-player/mpv)（原生窗口，非纹理回读） | 全格式、libass 完整字幕特效、GLSL 着色器 |
| 插件 | [QuickJS](https://bellard.org/quickjs/) | 逐插件隔离，崩溃/超时不影响宿主 |
| 遥测 | [Sentry](https://sentry.io)（前端 + Rust 双侧） | 崩溃堆栈与匿名活跃统计 |

## 仓库结构

```
crates/core/       各端共用的业务核心(数据源/网络/配置/同步/下载/插件)
apps/
  desktop/         Tauri 桌面壳 —— Windows / Linux
  android/         安卓壳(待建)
ui/
  shared/          各端共用前端层:api.ts(命令桥+类型) / theme.ts / tokens.css
  desktop/         桌面 UI
  mobile/  tv/     待建
public/            前端静态资源
scripts/           构建与校验脚本
oauth-proxy/       Cloudflare Pages Functions(OAuth 中转 / 徽章 / 赞助名单)
```

根级 `Cargo.toml` 是 workspace，`package.json` / `vite.config.ts` / `tsconfig.json` / `index.html` 是前端入口。

### 两条容易踩的约定

**`@shared` 别名定义在两个地方，必须逐字一致**——`vite.config.ts` 的 `resolve.alias` 与 `tsconfig.json` 的 `compilerOptions.paths`。只改一边的话 vite 构建是绿的、`tsc` 直接红，而 `npm run build` 是 `tsc && vite build`。

**版本的唯一权威是 `apps/desktop/tauri.conf.json` 的 `version`**。`build.rs` 拿它注入 `LP_VERSION` 给 Sentry release，`vite.config.ts` 拿它做 sourcemap release，`scripts/pack-portable.ps1` 拿它给 zip 命名。`Cargo.toml` 里的 version 不参与，两者没有任何同步机制——现在都是 `0.1.0` 纯属巧合。

## 本地开发

### 环境要求

- [Rust](https://rustup.rs/) stable
- **Node.js 24+**——`npm run check:telemetry` 让 node 直接跑 `.ts`（类型擦除，换来零测试框架）。Node 20 会报 `ERR_UNKNOWN_FILE_EXTENSION ".ts"`
- Tauri 2 的[平台依赖](https://tauri.app/start/prerequisites/)（Windows 需 WebView2 + MSVC 工具链；Linux 需 webkit2gtk 等）
- `apps/desktop/libmpv/libmpv-2.dll`——**117MB，不入库，需自备**

### libmpv

必须是 **shinchiro 的完整构建**：自带完整 ffmpeg，含 PGS/SUP 图形字幕解码器（`hdmv_pgs_subtitle`）。精简版能编译、能播放、**蓝光字幕一片空白**。

从 [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases/latest) 下最新的 `mpv-dev-x86_64-*.7z`，把 `libmpv-2.dll` 放进 `apps/desktop/libmpv/`。CI 每次构建会自动拉取（见 `.github/workflows/build.yml`），并断言体积 ≥ 60MB——少了 DLL 的话 exe 照样编得出来、照样打得成包，用户双击才发现「找不到 libmpv-2.dll」。

### 跑起来

```bash
npm install
npm run tauri dev          # 开发模式（前端 HMR + Rust 热重启）
npm run build              # tsc && vite build，只构前端
npm run tauri build        # 完整构建，产物在 target/release/
```

### 校验

```bash
cargo test --workspace                        # Rust 全量测试
npm run check:telemetry                       # 遥测脱敏断言
bash scripts/check-commands.sh                # 命令表定义/注册一致性
node scripts/check-calendar-grouping.mjs      # 日历归组逻辑
node ui/desktop/pages/favorites-sort.test.mjs # 收藏排序
```

部分 Rust 测试用 `include_str!` **直接读前端源码**做一致性断言（`apps/desktop/src/lib.rs`）。移动前端文件时要同步改这些路径，否则 `cargo build` 绿而 `cargo test` 红。

### 编译期凭据

弹弹play 默认弹幕源与 TMDB 排行榜需要编译期注入凭据，`crates/core/build.rs` 读这三个环境变量：

```
DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET / TMDB_API_KEY
```

**不给也能构建**，只是这两个功能静默缺席（UI 走诚实空态）。本地开发把它们放进仓库根的 `hjbl.env`（已 gitignore），`scripts/pack-portable.ps1` 会自动加载。

## 发布

只出**绿色免安装包**，不做 setup（`tauri.conf.json` 里 `bundle.active = false`）。

```powershell
npm run pack        # 完整：读 hjbl.env → 构建 → 传符号 → zip → 解压到测试目录
npm run pack:fast   # 跳过 zip，只刷新测试目录
```

脚本把 `dist-portable/` 分成三个互不重叠的目录——`build/`（干净产物，每次清空）、`.zip`（发给用户）、`LinPlayer/`（你自己测试的地方，保留 `userdata/`）。**分开是这个脚本的全部意义**：App 把账号和 token 写在 exe 同级的 `userdata/`，构建目录和测试目录一旦合并，要么打包清空你的登录态，要么**你的账号和 token 被打进 zip 发给所有人**。两种都真实发生过。

> `scripts/pack-portable.ps1` 必须是**纯 ASCII**：PowerShell 5.1 会把不带 BOM 的 UTF-8 中文当 GBK 读，直接解析失败。

CI（`.github/workflows/build.yml`）推 `main` 触发，产出 `v<ver>-pre` 预发布 = App 内的「预览版」渠道；`publish.yml` 手动把它提升为正式 Release = 「稳定版」渠道。两个渠道的定义就落在这两个文件上。

## 安卓端（重建中）

安卓 UI 尚未开始，壳也还没建。已定的两条：

- 直接链**现成的 libmpv `.so`**，不再自建 JNI 封装。
- `crates/core` 不依赖 tauri / windows-sys / 任何桌面专属 crate，就是为了能交叉编译成安卓 `.so`。改核心时请守住这条。

功能全清单见 [MIGRATION_RN_PLAN.md](MIGRATION_RN_PLAN.md)，落地记录见 [RUST_MIGRATION_PLAN.md](RUST_MIGRATION_PLAN.md)。

> Flutter 时代的构建方式（`flutter build apk` 等）已全部失效，代码见 tag `flutter-final`。
