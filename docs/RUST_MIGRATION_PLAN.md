# LinPlayer 重构规划书 · Dart → Rust 核心 + React/TS 前端 + Tauri 壳

> 生成日期：2026-07-14 · 承接 `docs/MIGRATION_RN_PLAN.md`(功能全清单 + RN 否决)
> 本文=**落地方案**:确定技术栈、Dart→Rust 核心迁移顺序、Windows 前端、mpv 集成、分阶段里程碑。
> 铁律:**先过 Phase 0 PoC 关,再正式动工。** 未验证的假设不许铺开。

---

## 0. 已锁定技术栈

| 层 | 选型 | 理由 |
|---|---|---|
| **前端 UI** | **React + TypeScript**(web,跑在 webview) | 华丽/动效/流畅生态之王;React ⟺ TS 不可分 |
| **桌面壳** | **Tauri v2** | 体积小(用系统 WebView2,Win10 ✅),后端就是 Rust |
| **后端/核心** | **Rust**(单一核心,桌面+安卓复用) | 原生无运行时=最小体积;交叉编译到各端;socket/mpv 强项 |
| **视频** | **libmpv-rs** 驱动**原生子窗口**,垫在透明 webview 下 | 真 mpv(PGS/Anime4K/硬解),结构性免闪屏 |
| **安卓/TV** | 待定(留 Flutter 或 webview UI);**Rust 核复用** via `flutter_rust_bridge` / `uniffi` | 逻辑一份两吃 |

**核心原则**:
- **TS 管脸,Rust 管里子**。UI 逻辑在 React;数据/网络/mpv/加密/插件在 Rust 核。
- **视频永不进 webview**——mpv 是原生一层,webview 只画透明 UI 盖在上面(Jellyfin Media Player / Plex 同架构,可参考其壳)。
- **Dart→Rust 是重写不是转译**。逻辑你都懂(你写的),但要逐模块解耦 Flutter 依赖再落 Rust。

---

## 1. 架构图

```
┌─────────────── React + TS (webview, 透明) ───────────────┐
│  首页/库/详情/播放OSD/设置/弹幕面板 …  华丽+动效           │
└───────────────┬─────────── Tauri IPC ────────────────────┘
                │ invoke / event
┌───────────────▼──────────── Rust 核心 ────────────────────┐
│  数据源(Emby/OpenList/夸克/ani-rss/飞牛)+ 302重签 + 聚合  │
│  播放控制(libmpv-rs)+ 字幕/音轨偏好 + 片头跳 + 上报        │
│  弹幕(签名/匹配/解析/缓存/过滤) 下载引擎(多线程Range)     │
│  网络(CF反代 钉IP+SNI / 预取本地server / SOCKS5 / UA)     │
│  同步(Trakt/Bangumi) 排行 日历 加密(备份/配置迁移) 插件   │
│  插件运行时 = rquickjs(Rust 绑定 QuickJS,沿用 JS 插件API) │
└───────────────┬──────────────────────────────────────────┘
                │ raw-window-handle
┌───────────────▼──────────── 原生子窗口 ───────────────────┐
│  libmpv 直出 D3D11(Win)/GL(Linux),DWM/合成器叠 UI → 不闪  │
└───────────────────────────────────────────────────────────┘

安卓/TV:同一份 Rust 核 → 交叉编译 .so → Flutter(flutter_rust_bridge)或 Kotlin(uniffi)
```

---

## 2. Dart → Rust 核心:模块映射与 crate 选型

> 参考功能清单见 `MIGRATION_RN_PLAN.md §1`。以下为"哪块 Dart 变成哪块 Rust"。

| Dart 现状 | Rust 落地 | 关键 crate |
|---|---|---|
| dio HTTP + 统一 UA | HTTP 客户端 + 默认头 | `reqwest` / `hyper` |
| Emby/OpenList/ani-rss/飞牛 鉴权(签名 md5/sha256) | 各源 client + 签名 | `sha2` `md-5` `hmac` `base64` |
| 夸克 Cookie 轮换 + 扫码 | Cookie jar + 设备码轮询 | `reqwest` cookie store + 持久化 |
| 302 重签 / TTL | 播放会话状态机 | 自写 |
| 聚合版本匹配 | 多服扇出 + 匹配 | `tokio` 并发 |
| media_kit/mpv 控制 | **libmpv-rs** | `libmpv2` / `libmpv-sys` |
| 字幕/音轨偏好正则 | 同逻辑 | `regex` |
| ASS→SRT / 时间偏移 | 文本处理 | 自写 |
| 弹幕 签名/匹配/解析/缓存/过滤 | 同逻辑 | `regex` `serde_json` `quick-xml` |
| 多线程 Range 下载 | 分段并发 + 断点 | `tokio` `reqwest` Range |
| **CF 反代 钉IP+SNI** | 自定义 connector | `hyper` + `rustls`(SNI/IP 完全可控,Rust 主场)|
| **预取本地 server** | 本地 HTTP server | `hyper` / `axum` |
| SOCKS5 代理 | 代理连接 | `tokio-socks` |
| 观看记录/续播指纹 | 匹配 + 本地库 | `rusqlite` / `redb` |
| Trakt(设备码 OAuth)/Bangumi | OAuth + API | `reqwest` `oauth2` |
| Emby 上报三件套(PlaySessionId 一致) | 会话贯穿 | 自写(注意 id 一致) |
| 排行(弹弹签名/TMDB AES) | 双源 + 解密 | `aes` `cbc` |
| 备份加密(PBKDF2+AES-GCM)/配置迁移(AES+gzip) | 同算法 | `pbkdf2` `aes-gcm` `flate2` |
| 凭据安全存储 | OS 钥匙串 | `keyring` |
| 便携化路径 | 目录重定向 | `dirs` / 自写 |
| Sentry 遥测 | 崩溃+活跃 | `sentry` (Rust) |
| **QuickJS 插件系统** | **rquickjs** 重建沙箱 + 权限 + 8s 超时 | `rquickjs`(Rust 绑 QuickJS)|
| 平台集成(文件选择/深链/通知) | Tauri 插件 | `tauri-plugin-*` |

**注意事项**
- **解耦 Flutter 依赖**:凡是 Dart 服务里用了 `flutter_secure_storage`/`path_provider`/`FilePicker` 的,落 Rust 时换成 `keyring`/`dirs`/Tauri 插件。
- **插件系统是最大重写块**:好在 `rquickjs` 让你能在 Rust 里继续跑 QuickJS,插件的 JS 侧 API(ctx.http/storage/player/…)可原样保留,只重写宿主桥。
- **PlaySessionId 一致性**:上报三件套必须同 id,这是续播落地的老坑,移植时首要保。

---

## 3. Windows 前端(React/TS)

- **框架**:React + TS;路由 React Router;状态 Zustand + TanStack Query。
- **动效**:Framer Motion / GSAP / CSS —— 华丽层就靠这里。
- **播放页**:React 画 OSD/面板(透明),视频是底下 mpv 原生窗口;进度/轨道/缓冲通过 Tauri event 从 Rust 核推上来。
- **弹幕渲染**:Web `<canvas>` / WebGL —— web 做高密度弹幕很强,是加分项。
- **与 Rust 通信**:`invoke`(命令)+ `event`(播放状态/进度/日志流)。
- **组件库**:可选 shadcn/Radix 等,自定义主题做"简洁+华丽"。

---

## 4. mpv 集成(#1 技术风险)

- `libmpv-rs` 在 Rust 核创建 mpv 实例,`--wid` 或 render API 绑定一个**原生子 HWND**(Win)/GL surface(Linux)。
- Tauri 窗口:webview 设透明,mpv 子窗口 z-order 在 webview 之下(或用 Tauri v2 多 webview / 原生层叠加)。
- **合成缝**(webview 与 mpv 窗口的位置/层级/缩放同步)= 全项目最大不确定点 → **Phase 0 必须先验**。
- 超分:Anime4K glsl-shaders 通过 mpv 属性喂(assets 运行时落地),沿用现有 6 个 CNN shader。

---

## 5. 分阶段里程碑(风险优先 → 价值优先)

### Phase 0 · PoC(硬门槛,不过不动工)
- Rust 核骨架 + Tauri + React 壳
- libmpv-rs 在原生子窗口放一段带 **PGS 字幕 + 一个 Anime4K shader** 的片
- React 画一个**带切换动效的面板**,弹出/收起验证**不闪**
- 同一份 Rust 核 `cargo build --target aarch64-linux-android` **编成 .so**(证明安卓可复用)
- ✅ 三条全过 → 继续;❌ 合成缝过不了 → 回头重估壳(Qt WebEngine 兜底)

### ✅ Phase 1 · 可播地基(Emby 打通)
Rust:HTTP+UA、Emby client、凭据存储、配置。React:服务器列表/登录/首页。**能登录并用 mpv 播一条 Emby 流。**

### ✅ Phase 2 · 播放完整度
轨道/字幕偏好匹配、ASS→SRT、片头跳、缓冲进度、**PlaySessionId 上报**、续播。React 播放页成型。

### ✅ Phase 3 · 数据源铺开
OpenList → ani-rss → 飞牛(authx)→ 夸克(Cookie+扫码)→ 聚合 + 302 重签。

### ✅ Phase 4 · 弹幕
Rust:签名/匹配/解析/缓存/过滤。React:canvas/WebGL 渲染(描边/轨道/密度/显示区域)。

### ✅ Phase 5 · 网络重活(Rust 主场)
多线程下载、**CF 反代(钉 IP+SNI)**、预取本地 server、SOCKS5。

### ✅ Phase 6 · 同步/周边
Trakt/Bangumi、排行双源、追剧日历、爱发电、配置迁移扫码。(备份加密 GCM 刻意不港:Dart 标注 legacy 仅向后兼容导入,新端无历史可导。)

### Phase 7 · 插件系统
rquickjs 重建引擎;JS 插件 API 保持兼容;**并借机重写实现形态**(不再走 Dart 的 `__lp_host` 字符串编组,改 Rust async 函数原生绑进 `ctx` 返回真 Promise,引导脚本 227 行→1 行)。

- **✅ Rust 引擎 + 命令(已证死)**:`crates/core/src/plugins/`——manifest/permission/storage(5MB)/extensions(注册表)/host(平台缝 trait,单一 `call(channel,method,args)`)/convert/state(权限门控+HTTPS 白名单+**30s 空转看门狗**:interrupt 只在 JS 真跑时触发,等宿主 await 期不触发)/ctx(原生绑 log/http/storage/player/ui/emby/extensions/cfproxy/sleep 九通道)/engine(AsyncRuntime+内存限 64MB+Drop 清 Persistent)/**worker(专用线程 actor:QuickJS 单线程,引擎钉线程永不跨线程)**/manager(Send+Sync 门面)。只支持 `runtime:js`(data/addon 是 iOS 合规专用,无 Apple 已砍)。src-tauri:`DesktopPluginHost` + 10 个 `plugin_*` 命令 + play/stop 钩 onPlay/onPlayEnd。单测 39 过(真 hello 插件逐字不改跑通全生命周期 + 权限拒绝),app release 绿。
- **⬜ React 宿主 UI(待接)**。对接契约已铺好:
  - **ctx.ui 渲染**:监听 Tauri 事件 `plugin://ui-request`(载荷 `{id,pluginId,method,args}`);`showForm/showDialog/showList/showProgress` 渲染后调命令 `plugin_ui_respond(id, value)` 回填(`value=null` 视为取消);`showToast/updateProgress/closeProgress/openPage` 是即发即忘(`id=0`)。
  - **扩展点渲染**:命令 `plugin_extensions(type_id)` 取某类型全部扩展(homeStats/sidebarItems/settingsPages…);触发 handler 用 `plugin_trigger(pluginId,type_id,ext_id,args?)`,具名字段(设置页 load/submit)用 `plugin_invoke_field(...,field,args?)`;注册表变化会发 `plugin://extensions-changed` 事件。
  - **管理页**:`plugin_list` / `plugin_install(path)` / `plugin_enable(id)` / `plugin_disable(id)` / `plugin_uninstall(id)`;启用前须自行弹权限同意弹窗(`plugin_list` 项含 `permissions`)。
  - 遗留:`getCredentials` 因 PoC 不存明文密码返 Err;cfproxy 重活未接(命令壳在)。

### Phase 8 · Linux + 安卓
- **✅ 安卓:一份 Rust 核交叉编译通过(证死)**。`cargo ndk -t arm64-v8a build --release -p linplayer-core` 产出 `target/aarch64-linux-android/release/liblinplayer_core.rlib`(8.6MB,`llvm-readobj` 验为 `EM_AARCH64` ELF64);**整核含 reqwest/rustls、tokio、数据源、网络、QuickJS 插件引擎全套**都过。可复现脚本:**`native-poc/scripts/build-android.sh [arm64-v8a|armeabi-v7a|...]`**。Windows 宿主特有的 bindgen 坑及解法(脚本已封装):
  - reqwest 从默认 native-tls **切 rustls-tls**(`default-features=false`),去掉 `openssl-sys`——安卓交叉编译免装 OpenSSL(桌面亦通用,`.resolve()`/`danger_accept_invalid_certs` 的 CF 钉 IP+SNI 在 rustls 下照常)。
  - rquickjs-sys 不随包发 android 的 FFI bindings → core/Cargo.toml 的 `[target.'cfg(target_os="android")']` 开 `bindgen` 现生成;`bindgen` 经 proc-macro `rquickjs-macro`(永远编 host)传导,**host+android 两个 bindgen 都要喂**。
  - 需一个**带 `libclang.dll` 的 NDK**(如 30.x;27.x 不带);libclang 当 DLL 加载 InstalledDir 为空 → 显式 `-resource-dir` 指 `lib/clang/<ver>`(补 stdbool.h);host(msvc)bindgen 还要从 `vcvars64.bat` 灌 `%INCLUDE%`(补 stdio.h);预置 `BINDGEN_EXTRA_CLANG_ARGS_<triple>` 后 cargo-ndk 不再补 sysroot,故自带 `--sysroot`。
- **⬜ 安卓 UI 未定**:Rust 核已就绪不阻塞;留 Flutter 走 flutter_rust_bridge 或 webview 走 uniffi;真出 `.so` 需一个 cdylib 绑定壳(core 是 rlib);TV 焦点方案另议。
- **⬜ Linux(需 Linux 机验)**:Tauri 跨平台;`.so`/GL 子窗口合成需 webkit2gtk + Linux target,Windows 宿主上无法验证,留到有 Linux 环境再证(风险低)。

---

## 6. 风险登记（开工前须知）

| 风险 | 级别 | 应对 |
|---|---|---|
| webview↔mpv 合成缝(位置/层级/缩放同步) | 🔴 | Phase 0 先验;兜底 Qt WebEngine(Jellyfin MP 架构) |
| Dart→Rust 是重写,工期以季度计 | 🟠 | 逻辑已知;按 Phase 切,先出可播 MVP |
| Rust 团队熟练度 | 🟠 | 核心只写一次,学习成本摊到各端;UI 仍是熟悉的 TS |
| 插件系统重写(QuickJS 宿主桥) | ✅ | Rust 引擎+宿主桥已落并证死(rquickjs 原生绑定,39 测过);剩 React 宿主 UI |
| 安卓 UI 未定 + TV 焦点 | 🟡 | Phase 8 再决;Rust 核先就绪不阻塞 |
| 夸克双鉴权/扫码 | 🟡 | 放 Phase 3 末;cookie store + 设备码 |

---

## 7. 立即下一步

1. **搭 Phase 0 PoC**(Tauri + React + Rust + libmpv-rs,验合成不闪 + 安卓可编)。
2. PoC 过 → 按 Phase 1 起 Emby 可播 MVP。
3. 每 Phase 结束回看 `MIGRATION_RN_PLAN.md §1` 勾功能,防遗漏。

> 一句话:**React/TS 画脸,Rust 当里子(libmpv-rs 驱动 mpv),Tauri 装成小体积原生壳,一份 Rust 核桌面安卓两吃。先 PoC 验合成缝,再逐 Phase 铺。**
