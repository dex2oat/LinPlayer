# LinPlayer 插件系统

一个基于 **QuickJS**（`flutter_qjs`）的插件系统：每个插件运行在独立的 JS isolate 中，
通过受权限控制的 `ctx` API 与主程序交互，并可向预定义的扩展点挂载自定义功能。

## 目录结构

```
lib/plugins/
├── plugin_system.dart            # 对外 barrel + 初始化入口
├── models/
│   ├── plugin_manifest.dart      # manifest.json 解析与校验
│   ├── plugin_permission.dart    # 权限定义 / 授予 / 校验
│   ├── plugin_extension_point.dart # 扩展点类型 + 平台支持表
│   └── plugin_info.dart          # 运行时插件状态
├── engine/
│   ├── plugin_js_engine.dart     # JS 引擎抽象接口
│   └── qjs_plugin_engine.dart    # flutter_qjs(IsolateQjs) 实现（唯一依赖三方包处）
├── runtime/
│   ├── plugin_bootstrap_js.dart  # 注入到每个插件的 ctx 引导脚本
│   ├── plugin_context_bridge.dart# 宿主侧 ctx.* 分发器（权限检查）
│   ├── plugin_runtime.dart       # 单插件运行时（加载/事件/超时）
│   ├── plugin_storage.dart       # 每插件 5MB 独立存储
│   ├── plugin_player_bridge.dart # 播放器事件/控制桥
│   ├── plugin_host_bindings.dart # 与运行中 App 的绑定（容器/导航器）
│   └── plugin_ui_host.dart       # ctx.ui 落地为 Flutter UI
├── manager/
│   ├── plugin_manager.dart       # 扫描/安装/启用/禁用/卸载/触发
│   ├── plugin_installer.dart     # .lpk 解压与校验
│   └── plugin_extension_registry.dart # 扩展点收集与渲染桥接
├── providers/plugin_providers.dart    # Riverpod providers
└── ui/
    ├── plugin_management_screen.dart  # 插件管理页（移动端）
    ├── plugin_permission_dialog.dart  # 权限同意弹窗
    └── plugin_settings_page_host.dart # 声明式设置页渲染
```

插件存储位置（`PluginManager._resolvePluginBaseDir`），目标是「卸载即清理、不残留」：

| 平台 | 基准目录 | 卸载是否自动清理 |
|------|----------|------------------|
| Windows / Linux（便携） | **可执行文件所在目录** | 删除应用文件夹即清理 |
| macOS（便携） | **.app 包同级目录**（移到 `/Applications` 则回退应用支持目录） | 删除解压文件夹即清理 |
| iOS / Android / tvOS / Android TV | **应用支持目录**（`getApplicationSupportDirectory`，沙盒内） | ✅ 系统卸载时随沙盒一并删除 |

设计要点：
- 桌面便携版把插件放在可执行文件/`.app` 同级，使整个解压文件夹**自包含**，
  删文件夹即清理，不散落到 AppData。
- 移动端/TV 无法把文件放到二进制旁边，但应用支持目录在**应用私有沙盒**内，
  **卸载时由系统连同沙盒一起删除**，天然不残留；且不污染用户可见的 Documents。
- 任何便携路径不可写（如装到只读位置）时，统一回退到应用支持目录。

- `plugins/<id>/`：安装后的插件文件（重装会整体覆盖该子目录）。
- `plugin_data/<id>/storage.json`：插件存储，**与插件目录分离**，所以升级/重装不丢数据。

## manifest.json

```json
{
  "id": "com.example.foo",          // 必填：反向域名，唯一
  "version": "1.0.0",               // 必填：语义化版本
  "name": "示例插件",                // 必填
  "author": "作者",
  "description": "一句话说明",
  "main": "main.js",                // 入口，默认 main.js
  "permissions": ["http", "storage"],
  "httpAllowedHosts": ["api.example.com", "*.cdn.example.com"],  // 联网必填，fail-closed
  "extends": {                      // 可选：静态声明扩展点
    "settingsPages": [
      { "id": "settings", "title": "设置", "handler": "openSettings" }
    ]
  }
}
```

## ctx API（暴露给插件）

| 能力 | 方法 | 所需权限 |
|------|------|----------|
| `ctx.log` | `info/warn/error` | 始终允许 |
| `ctx.http` | `get(url,opts)` / `post(url,body,opts)` | `http`（仅 HTTPS + 白名单） |
| `ctx.storage` | `get/set/delete/keys/clear` | `storage`（上限 5MB） |
| `ctx.player` | `getCurrentMedia` | `player.read` |
| `ctx.player` | `play/pause/seek` | `player.control` |
| `ctx.player` | `on(event,fn)/off(event,fn)` | `player.read` |
| `ctx.ui` | `showToast/showDialog/showForm/openPage` | `ui` |
| `ctx.emby` | `getCurrentUser/getServerUrl/getServerInfo` | `emby.read` |
| `ctx.emby` | `getCredentials()`（返回 username/password/url） | `emby.credentials` |
| `ctx.emby` | `apiRequest({method,path,query,body})` | `emby.api` |
| `ctx.extensions` | `register(type,desc)/unregister(type,id)` | `extensions` |

所有 `ctx.*` 调用都返回 Promise；权限不足会以 JS 异常形式 reject。

播放器事件：`onPlay` / `onPause` / `onPlayEnd`（用 `ctx.player.on` 订阅）。

## 扩展点

`sidebarItems`、`mediaSources`、`actions`、`eventListeners`、`settingsPages`、
`playerOverlays`、`contextMenus`、`homeStats`。

`homeStats`（首页统计指标）：handler 返回 `{ metrics: [{label, value}, ...] }`，
宿主渲染在首页媒体计数（电影/剧集/总共）旁边。**桌面端已接入**
（`desktop_home_screen.dart` 的 `_buildServerStats` + `PluginHomeStatsView`）；
移动端/TV 端按相同方式读取 `pluginRegistryProvider` 即可接。
示例见 `plugins_examples/uhdnow_traffic/`（uhdnow 服务器流量统计）。

- 静态：在 manifest 的 `extends` 声明；
- 动态：运行时 `ctx.extensions.register(type, descriptor)`。

主程序通过 `PluginExtensionRegistry` 收集，UI 监听该注册表渲染。
**TV 端**不支持 `playerOverlays` / `contextMenus`，加载时自动忽略并记录日志。

> 主程序侧已实现「收集 + 桥接」：移动端设置页内置插件管理与 settingsPages 渲染。
> 各端把自己的导航器通过 `attachPluginNavigator(key)` 注册后，即可让插件 UI 生效；
> 侧边栏/播放器覆盖层等扩展的渲染，由各端在读取 `pluginRegistryProvider` 后接入。

## 安全模型

- **权限声明制**：启用前弹窗征得用户同意（`plugin_permission_dialog.dart`）。
- **隔离**：每个插件一个 QuickJS isolate（`IsolateQjs`），内存上限 64MB；
  插件 JS 崩溃/死循环只影响自己的 isolate，**主程序始终响应**。
- **网络**：仅 HTTPS，且受 `httpAllowedHosts` 白名单约束 —— **fail-closed**：不写 =
  拒绝所有出网（不是放行）。支持 `*.example.com` 子域通配（不覆盖主域本身，裸 `*`
  不算通配）。重定向后的最终 host 也要在白名单内。实现见 `crates/core/src/plugins/state.rs`。
- **无文件系统**：不暴露 fs / 模块加载（`import` 被拒绝）。
- **超时**：每次进入 JS 的调用有墙钟超时（默认 8s）作为卡死保护，超时即判定
  插件失控、自动禁用并停止与之通信。
  - 注意：严格的「单次同步 CPU 1 秒预算」需要 QuickJS 原生中断；当前
    `flutter_qjs` 的 `IsolateQjs` 未透传 `timeout`，因此采用「独立 isolate +
    主线程墙钟超时」方案：失控插件被禁用、主程序不受影响（其代价是失控 isolate
    线程可能空转直到进程结束）。如需硬 CPU 中断，可改用 in-isolate `FlutterQjs`
    并设置 `timeout`，但那会在中断前短暂阻塞主 isolate。

## 打包与安装（.lpk）

`.lpk` = 含 `manifest.json` + `main.js`(+assets) 的 zip。

```bash
dart run tools/pack_plugin.dart <插件目录>
```

安装：设置 → 插件 → `+` 选择 `.lpk` → 解压到插件目录并校验清单 →
在列表中开启开关（同意权限后）即启用。启用状态存于 `shared_preferences`。

## 依赖说明

- **`flutter_qjs`（vendored 于 `third_party/flutter_qjs`）**：QuickJS 绑定。
  pub 上的 0.3.7 自 2021 起未维护，在 Dart 3.x 下无法编译——`lib/src/ffi.dart`
  的原生回调 `channelDispacher` 返回可空 `Pointer<JSValue>?`，而 Dart 3 要求
  `Pointer.fromFunction` 的回调返回**非空** Pointer；其 pubspec 还把 SDK 上界写成
  `<3.0.0`、ffi 锁 `^1.0.0`。因此把该包**复制进仓库并打补丁**：
  - `ffi.dart`：`channelDispacher` 改为返回非空 `Pointer<JSValue>`（查不到时
    `nullptr`），并给 `Pointer.fromFunction<_JSChannelNative>` 显式类型参数；
  - `pubspec.yaml`：SDK 放宽到 `<4.0.0`，ffi 放宽到 `>=1.0.0 <3.0.0`（与项目
    `ffi ^2.2.0` 兼容，**无需 dependency_overrides**）。
  - 主 `pubspec.yaml` 以 `flutter_qjs: { path: third_party/flutter_qjs }` 引用。
  - 已在 Windows 上 `flutter build windows` 验证：原生 quickjs.c 与 Dart 胶水均编译通过。
  - 若将来上游发布兼容版本，可换回 hosted 依赖；引擎实现抽象在
    `engine/plugin_js_engine.dart` 之后，替换 JS 引擎只需改 `qjs_plugin_engine.dart`。
- `archive ^3.6.1`：.lpk 解压与打包。
```
