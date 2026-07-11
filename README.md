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

<p align="center">
  <b>简体中文</b> ·
  <a href="README.en.md">English</a> ·
  <a href="README.ja.md">日本語</a>
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

## 界面预览

### 桌面端

> 截图内容来自 [**UHD MEDIA**](https://www.uhdnow.com)。

<table>
  <tr>
    <td width="50%"><img src="docs/images/screenshots/pc-home.png" width="100%" alt="首页"><br><sub><b>首页</b></sub></td>
    <td width="50%"><img src="docs/images/screenshots/pc-library.png" width="100%" alt="媒体库"><br><sub><b>媒体库</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-series-detail.png" width="100%" alt="剧集详情"><br><sub><b>剧集详情</b></sub></td>
    <td><img src="docs/images/screenshots/pc-movie-detail.png" width="100%" alt="电影详情"><br><sub><b>电影详情</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-rankings.png" width="100%" alt="排行榜"><br><sub><b>排行榜</b></sub></td>
    <td><img src="docs/images/screenshots/pc-search.png" width="100%" alt="搜索"><br><sub><b>搜索</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-favorites.png" width="100%" alt="收藏"><br><sub><b>收藏</b></sub></td>
    <td><img src="docs/images/screenshots/pc-settings.png" width="100%" alt="设置"><br><sub><b>设置</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/pc-add-server-1.png" width="100%" alt="添加服务器 1"><br><sub><b>添加服务器 ①</b></sub></td>
    <td><img src="docs/images/screenshots/pc-add-server-2.png" width="100%" alt="添加服务器 2"><br><sub><b>添加服务器 ②</b></sub></td>
  </tr>
  <tr>
    <td colspan="2" width="50%"><img src="docs/images/screenshots/pc-add-server-3.png" width="100%" alt="添加服务器 3"><br><sub><b>添加服务器 ③</b></sub></td>
  </tr>
</table>

### 移动端

> 截图内容来自 [**BAVA 服**](https://shop.mebimmer.de)。

<table>
  <tr>
    <td width="33%"><img src="docs/images/screenshots/mobile-home.jpg" width="100%" alt="首页"><br><sub><b>首页</b></sub></td>
    <td width="33%"><img src="docs/images/screenshots/mobile-series-detail.jpg" width="100%" alt="剧集详情"><br><sub><b>剧集详情</b></sub></td>
    <td width="33%"><img src="docs/images/screenshots/mobile-episode-detail.jpg" width="100%" alt="集详情"><br><sub><b>集详情</b></sub></td>
  </tr>
  <tr>
    <td><img src="docs/images/screenshots/mobile-movie-detail.jpg" width="100%" alt="电影详情"><br><sub><b>电影详情</b></sub></td>
    <td><img src="docs/images/screenshots/mobile-rankings.jpg" width="100%" alt="排行榜"><br><sub><b>排行榜</b></sub></td>
    <td><img src="docs/images/screenshots/mobile-settings.jpg" width="100%" alt="设置"><br><sub><b>设置</b></sub></td>
  </tr>
</table>

## 开发与技术

播放器内核对比、本地开发与构建、技术栈详见 **[开发文档 →](docs/DEVELOPMENT.md)**。

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
- [Bangumi (bgm.tv)](https://bgm.tv/) — 番剧追番进度与收藏同步
- [anibt](https://anibt.net) — 感谢站长为 LinPlayer 提供国内 Bangumi 反代（接口与图片加速），让追番同步开箱即用；亦是新生代 BT 磁力搜索站，资源丰沛、体验清爽，诚意推荐
- [Trakt](https://trakt.tv/) — 影视观看记录同步（Scrobble）
- [OpenList](https://github.com/OpenListTeam/OpenList) — 网盘聚合源

### Emby 服

感谢以下 Emby 服为 LinPlayer 提供界面演示与长期支持：

- [UHD MEDIA](https://www.uhdnow.com) — 桌面端截图内容来源
- [BAVA 服](https://shop.mebimmer.de) — 移动端截图内容来源

### 网络与代理

- [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — Android TV 内置代理内核
- [zashboard](https://github.com/Zephyruso/zashboard) — mihomo 控制面板
- [socks5_proxy](https://pub.dev/packages/socks5_proxy) — SOCKS 代理支持

### 脚本与工具

- [flutter_qjs](https://github.com/ekibun/flutter_qjs) / [QuickJS](https://bellard.org/quickjs/) — 插件脚本引擎（仓库内 vendored 打补丁）
- [dio](https://github.com/cfug/dio) / [extended_image](https://github.com/fluttercandies/extended_image) / [archive](https://pub.dev/packages/archive) 等 pub.dev 生态包

> 数据来源 TMDB 与弹弹play 的内容版权归各自所有；本项目仅作聚合展示，不存储或分发受版权保护的媒体。

## Star History

<a href="https://www.star-history.com/?type=date&repos=zzzwannasleep%2FLinPlayer">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&theme=dark&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=zzzwannasleep/linplayer&type=date&legend=top-left&sealed_token=YzGbSgSFzLcAXL2bfZUBGY625cNArNjNErV_fzvJkGSGpr_Xo8X3sXD8xRJf0Nehyt_OzmkyLq61xHqLXMn2i9APoG2uXgW_Z7nNRZArCQ-HjjGtU6fMFg" />
 </picture>
</a>

## 项目活跃度

![Alt](https://repobeats.axiom.co/api/embed/4858243f2148dfeaa4e82f119fa918f3ec581a11.svg "Repobeats analytics image")

## 赞助

感谢在 [爱发电](https://afdian.com/a/zzzwannasleep) 支持 LinPlayer 的各位（名单实时更新）：

<p align="center">
  <a href="https://afdian.com/a/zzzwannasleep"><img src="https://291277.xyz/afdian/sponsors.svg" alt="爱发电赞助者"></a>
</p>

## 加入频道

Telegram 频道 [**@MikudesuChannels**](https://t.me/MikudesuChannels) —— 版本发布、更新预告与讨论。
