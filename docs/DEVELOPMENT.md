# 开发与技术

> 播放器内核对比、本地开发与构建、技术栈。主文档见 [README](../README.md)。

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

CI 通过 **GitHub Actions** 自动构建：push 到 `main` 触发，产物在 [Actions](../../../actions) 页面的 Artifacts 中下载。

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
