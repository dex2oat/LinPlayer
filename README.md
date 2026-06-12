# LinPlayer

LinPlayer - Emby 第三方客户端移动端

## 功能特性

- **双播放器内核**：
  - **ExoPlayer**（Android 原生）：轻量稳定，支持文本字幕（SRT/ASS/WEBVTT/TTML）
  - **MPV**（media_kit）：全格式支持，HDR/Dolby Vision，原生支持 PGS/SUP 图形字幕
- **字幕支持**：自动加载 Emby 字幕流，支持字幕轨道切换、延迟调整、字体/大小/位置设置
- **手势控制**：亮度/音量/进度调节
- **播放上报**：完整的 Emby 播放进度同步
- **投屏支持**：DLNA 投屏

## 播放器内核对比

| 功能 | ExoPlayer | MPV (media_kit) |
|------|-----------|-----------------|
| 视频格式 | H.264/H.265/AV1 | 全格式 |
| 字幕格式 | SRT/ASS/WEBVTT/TTML | 全格式（含 PGS/SUP） |
| 字幕特效 | 基础 | libass 完整支持 |
| Dolby Vision | 部分支持 | 完整支持 |
| 超分辨率 | ❌ | Anime4K GLSL |
| 体积 | 较小 | 较大（+30MB） |
| 适用场景 | 普通视频 | 高质量/复杂字幕视频 |

## 自动构建

本项目配置了 **GitHub Actions** 自动构建：

### 自动触发
- Push 到 `main`/`master`/`develop` 分支时自动构建
- 支持手动触发（可选择 debug/release）

### 下载构建产物
1. 进入 [Actions](../../actions) 页面
2. 选择最新的 workflow run
3. 下载 Artifacts 中的 APK 文件

## 本地开发

### 环境要求

- Flutter 3.24.0+
- Dart 3.0+
- Android Studio / VS Code
- Android SDK 34+

### 构建步骤

```bash
# 克隆仓库
git clone https://github.com/yourusername/linplayer.git
cd linplayer

# 获取依赖
flutter pub get

# 构建 Debug APK
flutter build apk --debug

# 构建 Release APK
flutter build apk --release
```

### PGS/SUP 字幕支持

ExoPlayer 默认不支持 PGS/SUP 图形字幕。播放含此类字幕的视频时：
- 自动检测到 PGS/SUP 字幕
- **PC 端默认使用 MPV 内核**，完整支持 HDR/Anime4K/高级字幕控制
- 移动端可切换到 **MPV 内核** 获得完整支持

### Windows 端 MPV PGS/SUP 说明

media-kit 的 Windows 预编译 libmpv 为了减小体积禁用了 `hdmv_pgs_subtitle` 解码器，
导致 PC 版 MPV 默认无法渲染 PGS/SUP。构建时会**自动**用完整版 `libmpv-2.dll` 替换：

```powershell
flutter build windows
```

CMake 默认会在构建完成后调用 `windows/scripts/upgrade_libmpv_for_pgs.ps1`，
从 shinchiro 发布页下载完整版 `mpv-dev` 包并提取 `libmpv-2.dll`。
如果目标 DLL 已经包含 `hdmv_pgs_subtitle`，脚本会自动跳过，不会重复下载。
如果下载、解压、替换或校验失败，Windows 构建会直接失败，避免继续产出一个
“能启动但 PGS/SUP 一定不显示”的残缺包。

如需关闭自动升级：

```powershell
$env:LINPLAYER_SKIP_LIBMPV_UPGRADE = "1"
flutter build windows
```

或手动运行：

```powershell
.\windows\scripts\upgrade_libmpv_for_pgs.ps1
```

脚本成功后会在构建目录额外写入 `libmpv-upgrade.json` 作为校验记录。
替换后，MPV 内核即可正常解码并渲染 PGS/SUP 图形字幕。

## 项目结构

```
lib/
├── core/
│   ├── api/              # Emby API 接口
│   ├── providers/        # Riverpod 状态管理
│   └── services/         # 播放器服务
│       ├── exo_player_adapter.dart    # ExoPlayer 内核
│       ├── mpv_player_adapter.dart    # MPV 内核 (media_kit)
│       ├── subtitle_processor.dart    # 字幕处理
│       └── video_player_service.dart  # 播放器服务
├── ui/
│   └── screens/          # 页面
│       └── player/       # 播放器页面
└── main.dart

android/
├── app/                  # Android 应用模块
│   └── src/main/kotlin/  # 原生插件
│       └── ExoPlayerPlugin.kt
└── app/                  # Android 应用模块
```

## 技术栈

- **Flutter** - 跨平台 UI 框架
- **Riverpod** - 状态管理
- **media_kit** - libmpv 封装播放器
- **ExoPlayer** - Android 原生播放器
- **Emby API** - 媒体服务器通信

## 许可证

[LICENSE](LICENSE)

## 致谢

- [media-kit](https://github.com/media-kit/media-kit) - 跨平台媒体播放器
- [ExoPlayer](https://github.com/androidx/media) - Android 媒体播放器
- [Emby](https://emby.media/) - 媒体服务器
