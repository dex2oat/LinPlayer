# 桌面便携包:干净、隔离、可覆盖更新

LinPlayer 的 Windows / Linux 压缩包是**便携包**(绿色包):所有应用数据都写在**程序目录**内,
不往系统目录乱丢文件。每份解压目录是一套独立环境 —— 互不影响,适合「同机并存多版本」
或「本地构建 vs. GitHub 构建对照测试」。

> 便携**不是可选项,是默认且唯一的正常路径**。落盘路径只有一个出口:
> `crates/core/src/paths.rs`。别在别处自己拼 `dirs::xxx().join("LinPlayer")`。

## 解压后的目录结构

```
LinPlayer/
├─ LinPlayer.exe            ← 程序本体(Linux 上是无扩展名的 LinPlayer)
├─ libmpv-2.dll             ← 仅 Windows:内置完整版 libmpv(含 PGS/SUP 图形字幕解码器)
└─ userdata/                ← 你的全部身家 ★更新时保留★,删掉它=卸载干净
   ├─ config.json           ← 设置 / 服务器列表 / 凭据
   ├─ translation.json
   ├─ data/                 ← 用户数据:删了真会丢东西(观看记录、插件、whisper 模型)
   ├─ cache/                ← 纯缓存:随便删,能重建(封面、shader-cache、翻译)
   ├─ temp/                 ← 进程 TEMP/TMP 重定向到这里(连第三方库的临时文件也跑不掉)
   ├─ webview2/             ← WebView 的 profile,**含前端 localStorage,不能当缓存删**
   ├─ logs/
   └─ downloads/            ← 应用内下载
```

`cache/` 与 `data/` 分开不是洁癖 —— 它让「清理缓存」能是一句 `remove_dir_all(cache_root())`,
而不用逐个白名单挑文件(挑漏一个就是清不干净,挑错一个就是删用户数据)。

## 三条保证

1. **干净**:不写 `%APPDATA%` / `%LOCALAPPDATA%`(Windows)、不写 `~/.config` 与
   `~/.local/share`(Linux)、不进系统钥匙串。删掉解压文件夹 = 彻底清除。
   > 尤其按住了**浏览器内核自己**建的 profile:Windows 上显式给 WebView2 指定
   > `data_directory`;Linux 上 WebKitGTK 没有这个参数,改为在启动最早期把
   > `XDG_DATA_HOME` / `XDG_CACHE_HOME` 重定向进包内(见 `redirect_process_dirs()`)。
   > 不按住的话,光这一项实测就有 126MB 落在系统目录里。
2. **隔离**:每份解压目录只读写**自己的 `userdata/`**。解压两份分别跑 GitHub 包和
   本地包,配置互不串改 —— 可以放心对照测试整个安装流程。
3. **可覆盖更新**:更新包(zip)只含程序文件,**不含 `userdata/`**。
   把新版解压**覆盖**到旧目录即可,配置不丢。应用内更新走的也是同一条路。

## 平台前提

### Windows
开箱即用,libmpv 已内置在包里。

### Linux(x86_64)
- **需要系统 libmpv**(包里不自带):
  | 发行版 | 安装 |
  |:--|:--|
  | Debian / Ubuntu | `sudo apt install libmpv2`（旧版本叫 `libmpv1`） |
  | Fedora | `sudo dnf install mpv-libs` |
  | Arch | `sudo pacman -S mpv` |

  > 为什么不打包进去:构建机那份 libmpv 会连带一串特定版本的 ffmpeg/libass 依赖,
  > 而二进制里写了 `$ORIGIN` rpath —— **自带的那份会永远优先于系统的**。
  > 在别的发行版上,那就从「用系统上好好的库」变成「用一个依赖对不上的库」,反而更坏。
  >
  > 想自带某个版本:把 `libmpv.so.2` 放进解压目录即可,rpath 已经给你留好了这条路。

  libmpv 是**运行时 dlopen** 的,编译期不绑任何 soname,按 `libmpv.so.2` → `libmpv.so.1`
  → `libmpv.so` 的顺序尝试。所以**新旧发行版同一个包通吃**:Ubuntu 22.04 的
  `libmpv.so.1`(mpv 0.34)和 24.04/Fedora/Arch 的 `libmpv.so.2`(mpv 0.36+)都认。

  > 这不是锦上添花,是必需的:发行版之间 libmpv 的 soname 是分裂的,链接期绑死哪一个
  > 都会让另一半系统直接起不来 —— 绑 `.so.1` 则新系统「找不到库」,绑 `.so.2` 就得换更新的
  > 构建机,glibc 随之抬到 2.39,又反过来砍掉老系统。两条路都是死的。
  >
  > 一个字都找不到 libmpv 时,App 会明确告诉你装哪个包,而不是丢一句「mpv_create 失败」。

- **需要 X11**。Wayland 会话下会自动经 XWayland 运行(启动时设 `GDK_BACKEND=x11`)。
  这不是偷懒:视频是一个由程序**自己定位**的独立顶层窗口(垫在透明 UI 窗口正下方),
  而 Wayland 协议根本不提供「应用定位自己的顶层窗口」这种能力,mpv 的 `wid` 在
  Wayland 上也不受支持。
- 需要**合成器**(现代桌面环境默认都开)。没有合成的裸 WM 下,UI 窗口的透明区域不会
  真的透出下面的视频。
- 解压后记得 `chmod +x LinPlayer`(zip 格式不保存 Unix 权限位)。

## 边界情况

- **装到只读位置**(如 `C:\Program Files\`、只读挂载点):程序目录不可写,启动探针
  (真建目录 + 真写一个探针文件再删)失败 → 自动回落系统目录
  (Windows `%LOCALAPPDATA%` / Linux `~/.local/share`)。功能不受影响,但**不再便携** ——
  设置页会如实标出当前数据根的类型(`RootKind::SystemFallback`),绝不悄悄换地方。
  > 探针必须真写文件:Windows 的 Program Files 有 UAC 虚拟化,建目录「成功」了,
  > 写进去的东西却被悄悄重定向到 VirtualStore,一点错都不报。
- **指定数据根**:设环境变量 `LP_DATA_DIR` 可强制数据根位置(`RootKind::Overridden`)。
- **从旧版升级**:迁移挂在 `paths::root()` 的**首次调用**上自动执行,不是某处的一句显式
  调用 —— 那样只要调用顺序排错(比如 `AppConfig::load()` 抢先在新根落下一个空
  `config.json`),迁移就会认为「目标已存在」而跳过,老用户升级后**服务器全没了且不报错**。
