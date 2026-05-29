# MPV PGS 字幕支持方案

## 问题

media-kit 默认的 libmpv.so **缺少 PGS 字幕解码器** (`pgssub`)，导致 MPV 内核无法播放内封 PGS 字幕。

## 解决方案

### 方案 1：使用预编译的 mpv-android 库（推荐，最快）

mpv-android 项目编译的 libmpv.so **包含完整的解码器**，包括 PGS。

**步骤**：
1. 从 [mpv-android releases](https://github.com/mpv-android/mpv-android/releases) 下载 APK
2. 解压 APK，提取 `lib/arm64-v8a/libmpv.so`
3. 放入 `android/app/src/main/jniLibs/arm64-v8a/`
4. 替换 media-kit 下载的库

**缺点**：版本可能不匹配，需要手动操作。

### 方案 2：Fork 并修改 media-kit 构建仓库（最干净）

1. Fork `media-kit/libmpv-android-video-build`
2. 修改 `buildscripts/flavors/default.sh`
3. 添加 `--enable-decoder=pgssub`
4. 重新编译并发布
5. LinPlayer 使用自定义构建

**优点**：自动编译，可持续集成。
**缺点**：编译时间较长（约 30-60 分钟）。

### 方案 3：使用 full flavor（如果可用）

media-kit 的 `full` flavor 包含所有解码器，但 JAR 文件可能未发布。

---

## 当前实现

已创建 `.github/workflows/build-libmpv-pgs.yml`：
- 基于 media-kit 的构建脚本
- 自动启用 `pgssub` 解码器
- 编译所有架构（arm64-v8a, armeabi-v7a, x86, x86_64）
- 自动发布到 GitHub Releases

## 使用方法

### 1. 触发编译

```bash
# 手动触发
gh workflow run build-libmpv-pgs.yml

# 或推送代码自动触发
git push origin main
```

### 2. 等待编译完成

首次编译约 30-60 分钟（需要下载 NDK、编译 ffmpeg、mpv 等）。

### 3. 下载并使用

编译完成后：
1. 进入 Actions → Build libmpv with PGS support
2. 下载 artifacts
3. 解压到 `android/app/src/main/jniLibs/`
4. 修改 `pubspec.yaml` 移除或替换 media_kit_libs_video

### 4. 修改 pubspec.yaml

```yaml
dependency_overrides:
  media_kit_libs_video:
    path: ./custom_media_kit_libs  # 使用本地修改版本
```

或直接使用 jniLibs 中的 so 文件（需要修改 Gradle 配置）。

---

## 替代方案：ExoPlayer + FFmpeg 扩展

对于 ExoPlayer 内核，PGS 字幕可以通过 FFmpeg 扩展支持：

1. 确保 `build-ffmpeg.yml` 工作流正确编译
2. 确认 AAR 文件已放入 `android/exoplayer-ffmpeg/libs/`
3. ExoPlayer 会自动使用 FFmpeg 解码 PGS 字幕

已添加诊断日志，可以在 Logcat 中查看 FFmpeg 扩展是否正确加载。

---

## 总结

| 方案 | 难度 | 时间 | PGS 支持 |
|------|------|------|----------|
| MPV + 预编译 libmpv | 低 | 即时 | ✅ |
| MPV + 自定义编译 | 中 | 30-60分钟 | ✅ |
| ExoPlayer + FFmpeg | 中 | 15-25分钟 | ✅ |
| 当前 media-kit | 低 | 即时 | ❌ |

建议先尝试**方案 1**（下载 mpv-android 的 libmpv.so）快速验证，同时运行**工作流**编译长期解决方案。
