# LinPlayer

<p align="center">
  <a href="https://github.com/zzzwannasleep/LinPlayer/stargazers"><img src="https://img.shields.io/github/stars/zzzwannasleep/LinPlayer?style=flat&logo=github&label=Stars" alt="Stars"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?label=stable&color=blue" alt="Stable"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/v/release/zzzwannasleep/LinPlayer?include_prereleases&label=pre-release&color=orange" alt="Pre-release"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/releases"><img src="https://img.shields.io/github/downloads/zzzwannasleep/LinPlayer/total?label=downloads&color=green&logo=github" alt="Downloads"></a>
  <a href="https://github.com/zzzwannasleep/LinPlayer/blob/main/LICENSE"><img src="https://img.shields.io/github/license/zzzwannasleep/LinPlayer" alt="License"></a>
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter" alt="Flutter">
  <a href="https://github.com/zzzwannasleep/LinPlayer/actions"><img src="https://img.shields.io/github/actions/workflow/status/zzzwannasleep/LinPlayer/build.yml?branch=main&label=build&logo=github" alt="Build"></a>
  <a href="https://t.me/MikudesuChannels"><img src="https://img.shields.io/badge/Telegram-MikudesuChannels-26A5E4?logo=telegram&logoColor=white" alt="Telegram"></a>
</p>

**LinPlayer** 是一个跨平台的 Emby 第三方客户端，覆盖 **移动端（Android / iOS）**、**桌面端（Windows / Linux / macOS）** 与 **电视端（Android TV / tvOS）**，以 Flutter 作为唯一长期代码线演进。

> 每个平台使用各自的原生 UI 语言（Material / fluent_ui / macos_ui / TV 自适应），但共享同一套核心逻辑。

## 功能特性

- **双播放器内核**
  - **ExoPlayer**（Android 原生）：轻量稳定，支持文本字幕（SRT/ASS/WEBVTT/TTML）
  - **MPV**（media_kit / libmpv）：全格式支持，HDR / Dolby Vision，原生支持 PGS/SUP 图形字幕、Anime4K 超分辨率
- **弹幕**：接入弹弹play 等多后端，智能集数匹配、并行分源、描边/显示区域渲染，三端可用
- **排行榜**：弹弹play 动漫榜 + TMDB 影视榜（可开关）
- **多源浏览**：Emby 之外支持网盘/聚合源（OpenList、夸克 Cookie/扫码、Ani-rss 等）
- **字幕**：自动加载 Emby 字幕流，轨道切换、延迟调整、字体/大小/位置设置；MPV 走 libass 完整特效
- **下载**：自建多线程（Range 分段）下载引擎，三端统一
- **代理**：三端自定义代理 + CF 优选 IP 本地反代；Android TV 内置 mihomo 内核 + zashboard 面板
- **插件系统**：QuickJS 脚本引擎，每个插件独立 isolate，崩溃/超时隔离
- **投屏**：DLNA 投屏
- **遥控**：手机扫码遥控电视端（内置 HTTP 服务 + Web 控制页）
- **应用内更新**：双渠道（stable / pre）覆盖更新
- **播放上报**：完整的 Emby 播放进度同步，支持跨服务器续播

## 播放器内核对比

| 功能 | ExoPlayer | MPV (media_kit) |
|------|-----------|-----------------|
| 视频格式 | H.264/H.265/AV1 | 全格式 |
| 字幕格式 | SRT/ASS/WEBVTT/TTML | 全格式（含 PGS/SUP） |
| 字幕特效 | 基础 | libass 完整支持 |
| Dolby Vision | 部分支持 | 完整支持（gpu-next + 软解自动切换） |
| 超分辨率 | ❌ | Anime4K GLSL |
| 体积 | 较小 | 较大（+30MB） |
| 适用场景 | 普通视频 | 高质量/复杂字幕视频 |

## 本地开发

### 环境要求

- Flutter 3.24.0+ / Dart 3.0+
- Android SDK 34+（Android/TV 构建）
- Xcode（iOS/tvOS 构建）
- 桌面端对应的原生工具链（Windows / Linux / macOS）

### 构建

```bash
git clone https://github.com/zzzwannasleep/LinPlayer.git
cd LinPlayer
flutter pub get

# 各平台
flutter build apk --release        # Android / TV
flutter build windows              # Windows
flutter build linux                # Linux
flutter build macos                # macOS
flutter build ios                  # iOS / tvOS
```

CI 通过 **GitHub Actions** 自动构建：push 到 `main` 触发，产物在 [Actions](../../actions) 页面的 Artifacts 中下载。

### Windows 端 MPV PGS/SUP 说明

media-kit 的 Windows 预编译 libmpv 为减小体积禁用了 `hdmv_pgs_subtitle` 解码器，导致 PGS/SUP 默认无法渲染。构建时 CMake 会**自动**调用 `windows/scripts/upgrade_libmpv_for_pgs.ps1`，从 shinchiro 发布页下载完整版 `libmpv-2.dll` 替换。若目标 DLL 已含该解码器则自动跳过。

```powershell
# 跳过自动升级
$env:LINPLAYER_SKIP_LIBMPV_UPGRADE = "1"; flutter build windows

# 手动运行
.\windows\scripts\upgrade_libmpv_for_pgs.ps1
```

## 技术栈

- **Flutter** — 跨平台 UI 框架
- **Riverpod** — 状态管理，**go_router** — 路由
- **media_kit / libmpv** — MPV 播放内核，**ExoPlayer** — Android 原生内核
- **fluent_ui / macos_ui** — 桌面端原生风格，**TDesign** — 三端统一组件
- **flutter_qjs (QuickJS)** — 插件脚本引擎
- **dio** — 网络，**Emby API** — 媒体服务器通信

## 许可证

[LICENSE](LICENSE)

## 致谢

感谢以下开源项目、媒体服务与内核，LinPlayer 站在它们的肩膀上：

### 播放内核

- [media-kit](https://github.com/media-kit/media-kit) — 跨平台媒体播放器（libmpv 封装）
- [mpv](https://github.com/mpv-player/mpv) / [libmpv](https://github.com/mpv-player/mpv) — 全格式播放核心
- [ExoPlayer / androidx media](https://github.com/androidx/media) — Android 原生播放器
- [MPVKit](https://github.com/mpvkit/MPVKit) — tvOS 端 libmpv 集成
- [shinchiro mpv-winbuild](https://github.com/shinchiro/mpv-winbuild-cmake) — Windows 完整版 libmpv 预编译
- [Anime4K](https://github.com/bloc97/Anime4K) — 实时超分辨率 GLSL 着色器

### UI 与框架

- [Flutter](https://flutter.dev) / [Riverpod](https://riverpod.dev) / [go_router](https://pub.dev/packages/go_router)
- [TDesign Flutter](https://github.com/Tencent/tdesign-flutter) — 腾讯 TDesign 组件库（仓库内 vendored 打补丁）
- [fluent_ui](https://github.com/bdlukaa/fluent_ui) — Windows Fluent 风格
- [macos_ui](https://github.com/GroovinChip/macos_ui) — macOS 原生风格
- [flutter_animate](https://pub.dev/packages/flutter_animate) — 三端统一动效

### 服务与数据源

- [Emby](https://emby.media/) — 媒体服务器
- [弹弹play (DanDanPlay)](https://www.dandanplay.com/) — 弹幕与动漫排行榜数据
- [TMDB](https://www.themoviedb.org/) — 影视排行榜数据
- [OpenList](https://github.com/OpenListTeam/OpenList) — 网盘聚合源

### 网络与代理

- [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — Android TV 内置代理内核
- [zashboard](https://github.com/Zephyruso/zashboard) — mihomo 控制面板
- [socks5_proxy](https://pub.dev/packages/socks5_proxy) — SOCKS 代理支持

### 脚本与工具

- [flutter_qjs](https://github.com/ekibun/flutter_qjs) / [QuickJS](https://bellard.org/quickjs/) — 插件脚本引擎（仓库内 vendored 打补丁）
- [dio](https://github.com/cfug/dio) / [extended_image](https://github.com/fluttercandies/extended_image) / [archive](https://pub.dev/packages/archive) 等 pub.dev 生态包

> 数据来源 TMDB 与弹弹play 的内容版权归各自所有；本项目仅作聚合展示，不存储或分发受版权保护的媒体。

## Star History

<a href="https://star-history.com/#zzzwannasleep/LinPlayer&Date">
  <img src="https://api.star-history.com/svg?repos=zzzwannasleep/LinPlayer&type=Date" alt="Star History Chart" width="600">
</a>

## 项目活跃度

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## 加入频道

Telegram 频道 [**@MikudesuChannels**](https://t.me/MikudesuChannels) —— 版本发布、更新预告与讨论。
