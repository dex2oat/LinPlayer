# 三端原生渲染改造（治「开面板整屏闪」+「ANGLE 逐帧税」）

> 单一事实源。对话被 compact 后，从本文件继续。最后更新：2026-07-14。

## 0. 一句话目标

把桌面播放器从 **media_kit（mpv → 离屏纹理 → ANGLE(GLES→D3D11) 合成 → Flutter Texture）**
改成 **原生渲染（mpv 直接画到自己的原生窗口/表面，Flutter UI 叠加在其上）**，
消除「任何 UI 在视频上重绘 → 整屏丢一帧黑闪」的根，并去掉逐帧纹理拷贝税。

## 1. 根因（已用 6 次失败 + Hills 逆向双向坐实）

**症状**：Windows 上打开/滑动/悬停任何设置面板 → 整个画面闪一下（黑帧）。用户机
`dxva2-egl Failed to create EGL surface`（EGL 损坏）。

**根因**：media_kit 把 mpv 渲染成一张 Flutter Texture，经 **ANGLE** 合成。视频和 UI 在
**同一个 ANGLE 场景**里。该机 EGL 损坏 → 只要有东西在视频纹理上方重绘/改变图层结构，
整块外部纹理就 blank 一帧。**与面板是路由/就地、透明/不透明、有无裁剪都无关**（全试过，全闪）。

**证伪的假设（本会话踩过的坑，别再走）**：
- ❌ 路由 vs 就地 Navigator —— 就地 Offstage 一样闪（连悬停都闪）。
- ❌ 不透明面板挡住 —— 整屏还闪（闪是全屏级，不是面板区域级）。
- ❌ 去掉 ClipRRect/ListView 裁剪 —— 还闪。
- ✅ 唯一有效的 Flutter 层手段 = **全屏冻结帧**（截图盖住整个视频）——但会「画面冻结、声音继续」，
  用户否掉。说明：**只有让实时纹理彻底不出现在 ANGLE 场景里才不闪** → 即原生渲染。

## 2. Hills 逆向实据（`Hills_1.7.2.apk.apks`，同为 Flutter+mpv，从不闪）

反编译 `classes.dex`：
- `com.mountains.player.mpv.MPVView` extends **SurfaceView**（`SurfaceHolder`/`surfaceCreated`/`setZOrderMediaOverlay`）。
- `dev.jdtech.mpv.MPVLib` —— 用 **mpv-android**（libmpv 原生绑定），**不是 media_kit**。
- 一堆 `io.flutter.plugin.platform.PlatformView*` —— 通过 **Flutter PlatformView** 把原生视频视图嵌进 Flutter。
- `assets/shaders/Anime4K_*.glsl` —— 超分方案和我们一样。

**结论**：Hills = mpv 直画原生 Surface + Flutter UI 由系统合成器叠加。UI 重绘碰不到视频 surface → 永不闪，
且无逐帧拷贝 → 顺。**这就是正解的架构。**

## 3. 现有代码全景（4 个侦察 agent 实测，file:line 有据）

### 适配器接缝
- `lib/core/services/player_adapter.dart` —— 抽象 `PlayerAdapter`，关键 `Widget buildVideo()`、`int? textureId`、
  `screenshot()`、`applySuperResolutionLevel()`、`mpvCommand()`。
- `lib/core/services/video_player_service.dart:266` `_createAdapter()` 按平台+核心选适配器：
  - mpv + `Platform.isWindows && _windowsNativeRender` → `WindowsNativeMpvAdapter`（原生，现被开关封存）
  - mpv（默认）→ `MpvPlayerAdapter`（media_kit）
  - nativeMpv → `NativeMpvPlayerAdapter`（Android libmpv）
  - exoPlayer（Android 默认）→ `ExoPlayerAdapter`
- `buildVideo()` 经 `VideoPlayerService.buildVideo()` 暴露给三端播放页。

### 各平台当前渲染路径
| 平台 | 默认适配器 | 渲染方式 | 闪? |
|---|---|---|---|
| Windows | MpvPlayerAdapter | media_kit Texture（ANGLE） | **是** |
| Windows(原生开关) | WindowsNativeMpvAdapter | mpv 子 HWND 直连 D3D11，零 ANGLE | 否（但 UI 被盖） |
| Linux | MpvPlayerAdapter | media_kit Texture（原生 GL） | 未知（无 Linux 反馈） |
| macOS | MpvPlayerAdapter | media_kit Texture（软件纹理防 GL 泄漏） | 可能 |
| iOS | MpvPlayerAdapter | media_kit Texture | N/A（触屏无悬停） |
| Android | ExoPlayerAdapter / NativeMpvPlayerAdapter | Flutter Texture（SurfaceTexture 缓存末帧） | **否** |

### 三端播放页叠加结构（都把 buildVideo() 当普通 Stack 子节点，控件叠在同 Stack 顶层）
- 桌面 `lib/desktop/screens/player/desktop_player_screen_state.dart` build() 顶层 Stack：
  `buildVideo()`（子 0）→ 弹幕 → 缓冲 → 错误 → 手势 → 统计 → 控制栏 → …
- 移动 `lib/ui/screens/player/player_screen_state.dart:1563` 外层 Stack + 内层 Stack（video 在内层子 0）。
- TV `lib/tv/screens/player/tv_player_screen.dart:1058` Stack（`Center(buildVideo())` 子 0 + OSD 叠加）。
- **含义**：原生化后视频**不再是 Stack 里的 Flutter 组件**，而在 Flutter 层**之下**。三端播放页需把视频占位
  改成「透明 rect 上报器」（原生窗口跟随该矩形），控件继续在透明 Flutter 层上叠加——**叠加代码基本不动**，
  只是背后从 Texture 变成透明→透出原生视频。视频状态查询（isBuffering/hasError/position）走 provider，仍有效。

### Windows M1 现状（`windows/runner/native_mpv_render.{h,cpp}` + adapter）
- MethodChannel `com.linplayer/native_render`：init/setRect/getProperty/setProperty/command/applyShaders/dispose。
- C++：`CreateWindowExW(0, "LinPlayerMpvChild", WS_CHILD|WS_VISIBLE|WS_CLIPSIBLINGS, ..., host_window_)`
  —— host_window_ = Flutter view HWND；mpv `wid`=该子 HWND，`vo=gpu-next`+`gpu-context=d3d11`+`hwdec=d3d11va`。
- setRect = `MoveWindow`（无 SetWindowPos / 无 z-order / 无 WS_EX_LAYERED）。
- **M2 缺口**：WS_CHILD 子窗口按 Win32 z-order **天然画在父(Flutter)客户区之上** → 盖住 Flutter 控件。
  当前零合成基础设施。

### Android（关键：本就不闪，且特意没用 SurfaceView）
- `native_mpv_player_adapter.dart:741` buildVideo() 返回 `Texture(textureId)`。
- `MpvPlayerPlugin.kt`：`textureRegistry.createSurfaceTexture()` → `Surface` → `MPVLib.attachSurface(surface)`。
- `MpvSurfaceView.kt`(extends SurfaceView) + factory 已注册但**从不实例化**；注释明说「SurfaceView 会另起窗口层、
  和 Flutter 叠加控件冲突」→ 故意走 Texture。SurfaceTexture 缓存末帧 → **不闪**。

## 4. 目标架构（统一接缝，分平台实现）

**统一原则**：新增/复用「原生渲染适配器」，`buildVideo()` 返回一个**透明占位**（上报矩形或走 PlatformView），
视频由原生渲染，不进 ANGLE 共享纹理；Flutter UI 照旧在透明背景上叠加。

| 平台 | 方案 | 难度 | 说明 |
|---|---|---|---|
| **Windows** | mpv 子窗口 + **透明 Flutter 覆盖**（M2） | 高（硬骨头） | Win 无官方 PlatformView，需 runner 层做窗口层级+透明合成 |
| **Linux** | 同 Windows 思路（X11/Wayland `--wid` + GTK 透明覆盖） | 高 | 先看 Linux 是否真闪，不闪则延后 |
| **Android** | **维持现状**（Texture，不闪） | 无 | 别改成 SurfaceView（会弄坏叠加）；已达标 |
| **macOS** | PlatformView(NSView) + libmpv/MPVKit 渲 CAMetalLayer | 中 | Apple 有 PlatformView，叠加免费；顺带治 GL 泄漏黑屏 |
| **iOS** | PlatformView(UIView) + libmpv/MPVKit | 中 | 无悬停不闪，但可统一架构+去 ANGLE 税 |

## 5'. Windows M2 已实现方案（2026-07-14，挖洞法，待真机验 ANGLE 穿透）

**用户拍板**：选「挖洞原生」（AskUserQuestion）——弹幕转 ASS 由 mpv 画，面板/控制栏零改动零闪。
**M2 蓝图 agent 结论**：Windows 无低成本方案让 Flutter 实时 UI 与独立 mpv D3D11 窗口做每像素 alpha 合成
（透明窗撞 ANGLE flip-model；DComp 要 fork 引擎）。唯一干净路 = **区域挖洞**（`SetWindowRgn`）。

**已落实现**（全部 opt-in，`_windowsNativeRender` 开关，默认 media_kit）：
- `windows/runner/native_mpv_render.cpp`：mpv 改为**顶层窗口的兄弟子窗口**（父=顶层，非 Flutter 视图），
  `WS_CHILD` 去掉 `WS_CLIPSIBLINGS`，`SetWindowPos(HWND_BOTTOM)` 压最底；`osc=no`（Flutter 控件接管）。
  新 `SetHole(video, cutouts)`：在 **Flutter 视图窗口**上 `SetWindowRgn` = 整视图 −（视频洞 − cutouts）；
  `ClearHole()` 离场还原。`setRect` 通道多收 `cutouts:[[l,t,w,h]...]`（物理像素）。
- `flutter_window.cpp`：`NativeMpvRender::Create(messenger, GetHandle()顶层, view HWND)`。
- `windows_native_mpv_adapter.dart`：占位组件上报视频物理矩形 + 控制栏上/下条高度（100+safeTop / 140+safeBot）；
  `setChrome(controls/panelFraction)` + `reportGeometry` → `_pushHole()` 合并算 cutout，payload 变更才打通道。
- `video_player_service.dart`：`setNativeChrome(controls:)` 透传（仅 WindowsNativeMpvAdapter 生效）。
- `player_settings_panel.dart`：全局 `nativeRenderPanelFraction` 广播面板占屏宽比例，关闭清 0。
- `desktop_player_screen_state.dart` build()：每帧 `_playerService.setNativeChrome(controls: _showControls)`。

**唯一未验证的致命假设**：`SetWindowRgn` 挖 Flutter 视图（ANGLE flip-model swapchain 子窗口）的洞，
能否真的透出其下的 mpv 兄弟窗口。M2a（只挖顶层窗口）实测「没看到洞」→ 证明顶层区域管不到子窗口，
故改挖 Flutter 视图本身。**待真机验**：开原生 + 播视频 → 洞里出视频=成；界面照旧黑画面无视频=ANGLE 无视区域→转 DComp 备选。

**验后待办**（成立后）：弹幕转 ASS 喂 mpv、手势层输入转发、缓冲转圈、字幕/音轨/续播/Emby 上报平价、Linux/mac/iOS。

## 5. Windows M2 技术方案（原始调研，保留备查）

**要求**：mpv（自有 D3D11 窗口、零 ANGLE）显示在 Flutter UI **之下**，Flutter 透明处透出视频、不透明处（控件）盖住。

**选定路线：透明 Flutter 覆盖 + 底层 mpv 窗口**（唯一能既绕开 ANGLE 又叠 UI 的路）：
1. runner 让 **Flutter 视图窗口支持每像素透明**（ANGLE surface 带 alpha + DWM 合成；Flutter Windows 可做透明窗）。
2. mpv 窗口置于 Flutter 内容**之下**（重排窗口层级：mpv 为底层，Flutter 视图为其上的透明层）。
3. Flutter Scaffold/播放页背景在视频区**透明**（`Colors.transparent`），控件不透明 → 透出 mpv、盖住控件。
4. 视频矩形跟随（现有 setRect 机制）；全屏/DPI/resize 同步。

**待研究确认的技术点**（动手前 dive deep）：
- Flutter Windows 开启透明窗的确切改法（runner `Win32Window`/`FlutterWindow` + ANGLE EGL_ALPHA_SIZE + DWM）。
- 窗口层级重排：mpv 作 main window 的 WS_CHILD 且 z-order 在 Flutter view 之下，或 mpv 作 main、Flutter view 作透明子。
- 参考：其他 Flutter Windows 原生视频叠加实现（fvp / 社区方案）。

**备选（若透明窗走不通）**：分离顶层 layered overlay 窗口承载 Flutter UI（复杂、输入路由麻烦），最后手段。

## 6. 执行顺序 + 验收（真机只有用户能看画面 → 每步交付必须用户验）

1. **Windows M2**（本命）：透明覆盖 → mpv 底层 → 控件叠回 → 输入/全屏/DPI/resize。
   验收：开面板不闪 + 控件正常 + 播放顺 + 超分照旧。
2. **Windows M3**：把 WindowsNativeMpvAdapter 的方法补齐到 media_kit 平价（字幕轨/续播/Emby 上报/连播/截图）。
3. **Linux**：先真机确认是否闪；闪则套 Windows 方案。
4. **Android**：确认不闪（应免改）；只在发现 Texture 路有额外卡时才评估。
5. **macOS/iOS**：PlatformView + libmpv 原生视图，去 ANGLE 税、治 macOS GL 黑屏。
6. 全程：默认关（opt-in 开关）直到某平台 M2 稳，再切默认。media_kit 保留为回退。

## 7. 硬约束/教训（血泪，别重犯）

- media_kit 加 shader 前 `grep -c '//!COMPUTE'` 必须 0（ANGLE 蓝屏）。
- media_kit 永不 `setSize`（此机 dxva2-egl 坏 → setSize resize 渲染面 → GPU 击穿蓝屏，3/3 铁证）。
- 超分 = 标准 Anime4K Medium 六档（modeA/B/C + AA/BB/AC），用户已定，别再换 ArtCNN/FSR/CAS。
- 原生渲染**治得了闪**（视频离开 ANGLE 场景）；**治不了「4K 超分卡」**（那是 shader GPU 算力随输出像素暴涨，
  物理，换渲染器无用）——别对用户过度承诺「原生就不卡了」。
- `VideoPlayerService` 非单例（每进播放页 new）→ 跨会话状态走 static+SharedPreferences（`_windowsNativeRender` 已如此）。
- Windows 原生数字键超分：键盘焦点在 Flutter 顶层，mpv 子窗口 WS_CHILD 不抢焦点 → mpv keybind 是死码，
  数字键必须在 Flutter `_handleKeyEvent` 处理（M2 后控件叠回则用正常菜单）。
