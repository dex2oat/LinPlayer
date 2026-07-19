//! **唯一的落盘路径出口。** 全 App 只有这一个数据根,别再自己 `dirs::xxx().join("LinPlayer")`。
//!
//! ## 铁律:本项目是压缩包(绿色包)分发的
//! 用户**解压即用、删文件夹即卸载**。所以数据、缓存、临时文件、WebView2 profile ——
//! 一个字节都不许落在 exe 所在文件夹之外。便携**不是可选项,是默认且唯一的正常路径**。
//!
//! ## 重构前:7 个根,没有一个在包里
//!
//! | 旧位置 | 装的什么 |
//! |---|---|
//! | `dirs::config_dir()/LinPlayer` (Win=**Roaming**) | config.json / watch_history / icons / danmaku_cache / ranking_cache / shaders |
//! | `dirs::cache_dir()/LinPlayer` (Win=Local) | images / shader-cache / translation |
//! | `dirs::data_dir()/LinPlayer` | translation 的另一半 |
//! | `%APPDATA%/com.linplayer.poc/plugins_root` (**按 Tauri identifier 命名**) | 插件 |
//! | `%LOCALAPPDATA%/com.linplayer.poc/EBWebView` | **WebView2 profile,实测 126MB**,装着前端 localStorage |
//! | `%TEMP%/linplayer_*.log`(散在 TEMP 根,不带子目录) | 日志 |
//! | `<exe 同级>/downloads` | 下载 |
//!
//! Roaming 那条尤其毒:域账户登录会把几 GB 封面缓存跟着漫游过去。
//! EBWebView 那条最阴:**不是我们的代码写的**,是 WebView2 运行时自己建的 ——
//! 光把自家 `dirs::` 调用收拢干净,它照样在系统里留 126MB。必须显式把它按进包里。
//!
//! ## 现在的形状(全在解压目录里)
//! ```text
//! <解压目录>/
//! ├── LinPlayer.exe
//! └── userdata/            ← 全部身家都在这儿,删掉=卸载干净
//!     ├── config.json      ← 设置/账号
//!     ├── translation.json
//!     ├── data/            ← 用户数据:删了真会丢东西(观看记录/插件/whisper 模型)
//!     ├── cache/           ← 纯缓存:随便删,能重建
//!     ├── temp/            ← 进程 TEMP/TMP 重定向到这里(连第三方库的临时文件也跑不掉)
//!     ├── webview2/        ← WebView2 profile(含前端 localStorage,**不能当缓存删**)
//!     ├── logs/
//!     └── downloads/
//! ```
//! `cache/` 与 `data/` 分开不是洁癖 —— 它让"清理缓存"能是一句 `remove_dir_all(cache_root())`,
//! 而不用逐个白名单挑文件(挑漏一个就是清不干净,挑错一个就是删用户数据)。

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

static ROOT: OnceLock<PathBuf> = OnceLock::new();

/// 由宿主显式指定数据根(安卓侧用:那边根本没有 XDG/AppData,得由 Java 层给沙盒目录)。
/// 必须在任何一次 [`root`] 调用**之前**设;设晚了返回 Err,免得一半模块用旧根一半用新根。
pub fn set_root(p: impl Into<PathBuf>) -> Result<(), String> {
    ROOT.set(p.into()).map_err(|_| "数据根已被使用,不能再改".to_string())
}

/// 数据根。优先级:`set_root` > `LP_DATA_DIR` > **exe 同级 `userdata/`(默认)** > 系统目录(兜底)。
///
/// 绿色包分发 → 默认就是 exe 同级,不需要任何 marker 文件。只有 exe 目录**写不进去**
/// (解压到 Program Files / 只读盘)才回落系统目录 —— 那会破坏"全在包里"的承诺,
/// 所以 [`root_kind`] 会把真实情况报给设置页明说,绝不悄悄换地方。
///
/// **首次调用时自动跑一次旧数据迁移**,所以不存在"忘了在启动时先调 migrate"这种失败模式。
///
/// 这不是多此一举:第一版把迁移写成 `run()` 里的一句显式调用,而 `AppConfig::load()` 恰好排在
/// 它前面 —— load 读不到就 gen device_id 并立刻 save(),在新根落下一个空 config.json;
/// 迁移随后看见目标已存在就跳过(它绝不覆盖新数据),旧根里的账号/token 永远搬不过来。
/// 顺序错了**不报错**,只是用户升级后"服务器全没了"。靠注释提醒"要第一个调"是纸糊的,
/// 把迁移钉在取路径这唯一入口上才是真的关不掉。
pub fn root() -> PathBuf {
    let r = ROOT.get_or_init(resolve_root).clone();
    ensure_migrated(&r);
    r
}

/// 数据根落在哪儿、为什么。设置页要如实告诉用户,别让他猜。
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize)]
pub enum RootKind {
    /// 正常:exe 同级 userdata/ —— 绿色包该有的样子。
    Portable,
    /// 被 LP_DATA_DIR 指定。
    Overridden,
    /// **异常**:exe 目录写不进去(Program Files/只读盘),被迫落系统目录。UI 必须显眼提示。
    SystemFallback,
}

static KIND: OnceLock<RootKind> = OnceLock::new();

/// 当前数据根的类型。会先解析 root。
pub fn root_kind() -> RootKind {
    root();
    KIND.get().copied().unwrap_or(RootKind::Portable)
}

fn resolve_root() -> PathBuf {
    if let Some(p) = std::env::var_os("LP_DATA_DIR").filter(|s| !s.is_empty()) {
        let _ = KIND.set(RootKind::Overridden);
        return PathBuf::from(p);
    }
    // ★ 默认:exe 同级。绿色包分发,数据必须跟着解压出来的文件夹走,不需要任何 marker。
    if let Some(p) = exe_userdata().filter(|p| is_writable(p)) {
        let _ = KIND.set(RootKind::Portable);
        return p;
    }
    /* 兜底:exe 目录写不进去。Win=%LOCALAPPDATA% / Linux=~/.local/share。
       **故意不用 config_dir()**:那在 Windows 上是 Roaming,会把几 GB 缓存跟着域账户漫游。 */
    let _ = KIND.set(RootKind::SystemFallback);
    dirs::data_local_dir()
        .or_else(dirs::data_dir)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("LinPlayer")
}

fn exe_userdata() -> Option<PathBuf> {
    Some(std::env::current_exe().ok()?.parent()?.join("userdata"))
}

/// 真的建目录 + 真的写一个探针文件再删。**不能只看 `create_dir_all` 成不成** ——
/// Windows 的 Program Files 有 UAC 虚拟化:建目录"成功"了,写进去的东西却被悄悄重定向到
/// VirtualStore,用户在包里死活找不到自己的数据,而且一点错都不报。
fn is_writable(dir: &Path) -> bool {
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }
    let probe = dir.join(".write-probe");
    let ok = std::fs::write(&probe, b"1").is_ok();
    let _ = std::fs::remove_file(&probe);
    ok
}

fn ensure_migrated(root: &Path) {
    static MIGRATED: OnceLock<()> = OnceLock::new();
    // migrate_legacy 只用传进去的 root + dirs::,**绝不回调 root()** —— 回调就是 OnceLock 重入。
    MIGRATED.get_or_init(|| migrate_legacy(root));
}

/// 建好目录再返回。建不出来也返回路径(调用方写盘时自会报错),不 panic。
fn ensure(p: PathBuf) -> PathBuf {
    let _ = std::fs::create_dir_all(&p);
    p
}

/// 唯一的设置文件。
pub fn config_file() -> PathBuf {
    ensure(root()).join("config.json")
}

/// 用户数据根(删了会丢东西)。
pub fn data_root() -> PathBuf {
    ensure(root().join("data"))
}

/// 缓存根(随便删)。清缓存直接对它 `remove_dir_all`。
pub fn cache_root() -> PathBuf {
    ensure(root().join("cache"))
}

/// `data/<name>`,已建好。
pub fn data_dir(name: &str) -> PathBuf {
    ensure(data_root().join(name))
}

/// `cache/<name>`,已建好。
pub fn cache_dir(name: &str) -> PathBuf {
    ensure(cache_root().join(name))
}

/// 日志目录。**不再往 %TEMP% 根撒 linplayer_*.log**。
pub fn logs_dir() -> PathBuf {
    ensure(root().join("logs"))
}

/// 本 App 的临时目录。启动时进程的 `TEMP`/`TMP`/`TMPDIR` 会被指到这儿
/// (见 `src-tauri` 的 `redirect_process_dirs`),所以连第三方库、ffmpeg/whisper 子进程
/// 的临时文件也跑不出包 —— 这比"逐个把自家 temp_dir() 调用改掉"可靠:
/// 后者是白名单,漏一个就又往系统 %TEMP% 拉一坨。
pub fn temp_dir() -> PathBuf {
    ensure(root().join("temp"))
}

/// WebView2 / WebKitGTK 的 profile 目录。
///
/// **这是最容易漏的一个**:它不由我们的代码写,是 WebView2 运行时自己建的,
/// 默认落 `%LOCALAPPDATA%\<identifier>\EBWebView`(实测 126MB)。光收拢自家
/// `dirs::` 调用根本管不到它,必须在建窗口时显式把 data_directory 指到这里。
///
/// **不能放 cache/**:前端的 localStorage(弹幕显示设置、搜索历史)存在里面,
/// 被"清理缓存"删掉 = 用户设置无声蒸发。
pub fn webview_dir() -> PathBuf {
    ensure(root().join("webview2"))
}

/// 用户没自定义时的默认下载目录。
/// 旧实现是 `<exe同级>/downloads` —— 装到 Program Files 直接写不进去(或被 UAC 虚拟化到
/// VirtualStore,用户在下载文件夹里死活找不到文件)。
pub fn downloads_dir() -> PathBuf {
    ensure(root().join("downloads"))
}

/// 缓存占用字节数(递归)。UI 的"清理缓存"要显示它。含 temp/ —— 它也是清得掉的那部分。
/// **不含 webview2/**:那里有 localStorage,不归"缓存"管。
pub fn cache_size() -> u64 {
    dir_size(&root().join("cache")) + dir_size(&root().join("temp"))
}

fn dir_size(p: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(p) else { return 0 };
    rd.flatten()
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(t) if t.is_file() => e.metadata().map(|m| m.len()).unwrap_or(0),
            _ => 0, // 符号链接不跟进:跟进可能算重或走进死循环
        })
        .sum()
}

/// 清空缓存 + 临时文件。config / data / downloads / webview2 一根汗毛都不许动。
pub fn clear_cache() -> Result<(), String> {
    let root = root();
    for n in ["cache", "temp"] {
        let d = root.join(n);
        if d.exists() {
            std::fs::remove_dir_all(&d).map_err(|e| format!("清理 {n} 失败: {e}"))?;
        }
    }
    /* temp/ 必须立刻重建:进程的 TEMP 环境变量指着它,目录没了之后任何
       第三方库写临时文件都会失败(而且报的错跟"清过缓存"八竿子打不着,极难查)。 */
    let _ = std::fs::create_dir_all(root.join("temp"));
    Ok(())
}

// ---------- 一次性迁移 ----------

/// 把旧的 6 个根里**值钱的东西**搬进新根。缓存不搬 —— 它能重建,搬它只是给自己加风险;
/// 旧缓存直接删,免得在磁盘上烂着占空间(用户说的"乱拉"就包括这些没人管的残留)。
///
/// 幂等:搬完旧路径就没了;新的已存在就跳过(绝不覆盖新数据)。
/// 失败**不能**阻断启动 —— 迁移失败最多是数据回到初始态,而 panic 是直接打不开。
///
/// ⚠️ 私有且**只用参数 root**:公开的 `root()` 会调它,回调 `root()` 就是 OnceLock 重入。
fn migrate_legacy(root: &Path) {
    /* 跑测试时**绝不**碰开发机上真实的 AppData。
       这不是洁癖:本次重构中一次普通的 `cargo test` 就把开发者真实的 config.json
       (两个带 token 的账号)从 %APPDATA%\LinPlayer 搬走了 —— 因为 image_cache 的测试
       会调 cache_dir() → root() → 迁移。而 root 现在默认是 exe 同级,测试的 exe 在 target/ 下,
       于是 `cargo clean` 就等于删账号。
       migrate_from 本身是纯的(旧根全从参数进来),测试直接测它。 */
    if cfg!(test) {
        return;
    }
    migrate_from(
        root,
        dirs::config_dir(),
        dirs::cache_dir(),
        dirs::data_dir(),
        dirs::data_local_dir(),
    );
}

/// 真正的迁移实现。**旧根从参数进来而不是自己去问 `dirs::`** —— 否则这段代码根本没法测:
/// 测试一跑就会把开发机上真实的 `%APPDATA%\LinPlayer` 搬进临时目录。
/// 而"用户升级后账号还在不在"恰恰是全项目最贵的一条路径,不测不行。
fn migrate_from(
    root: &Path,
    roaming_base: Option<PathBuf>,
    cache_base: Option<PathBuf>,
    data_base: Option<PathBuf>,
    // local_base = `dirs::data_local_dir()` —— 上一版把根定在这儿(新布局),也是 SystemFallback 的落点。
    local_base: Option<PathBuf>,
) {
    let old_roaming = roaming_base.as_ref().map(|d| d.join("LinPlayer"));
    let old_cache = cache_base.as_ref().map(|d| d.join("LinPlayer"));
    let old_data = data_base.as_ref().map(|d| d.join("LinPlayer"));
    let (data, cache) = (root.join("data"), root.join("cache"));

    /* ★ 先处理"上一版的新布局根"(系统本地目录下、已经是 config.json + data/ + cache/ 的形状)。
       两种来路都真实存在:
         1. 曾经跑过把根定在系统目录的版本(本项目就出过这么一版,把真账号搬了过去);
         2. 现在的 SystemFallback —— exe 目录不可写时数据就落在那儿,之后用户把包挪到可写位置
            再启动,就得把数据接回包里,否则账号凭空消失。
       必须排在下面的老布局搬运**之前**:它更新,该赢。 */
    if let Some(prev) = local_base.as_ref().map(|d| d.join("LinPlayer")) {
        if prev != root {
            move_item(&prev.join("config.json"), &root.join("config.json"));
            move_item(&prev.join("translation.json"), &root.join("translation.json"));
            for n in ["watch_history.json", "plugins", "whisper-models", "bin"] {
                move_item(&prev.join("data").join(n), &data.join(n));
            }
            move_item(&prev.join("cache").join("icons"), &cache.join("icons"));
            // 它的 cache/ 剩下的部分能重建,直接清掉,别在系统里烂着
            let _ = std::fs::remove_dir_all(prev.join("cache"));
            let _ = std::fs::remove_dir_all(prev.join("temp"));
            let _ = std::fs::remove_dir_all(prev.join("logs"));
            let _ = std::fs::remove_dir(prev.join("data"));
            let _ = std::fs::remove_dir(&prev);
        }
    }

    /* 老 Flutter 桌面版(2026-07-15 已整体删除)的遗留:`<LinPlayer>/Linplayer/` 子目录。
       **只清它的纯缓存**(实测封面缓存 60MB + 视频流缓存),能重建,留着纯属白占磁盘。

       ★ 绝不碰它 Roaming 侧的 shared_preferences.json / flutter_secure_storage.dat /
       watch_history.json —— 那是**另一个应用的用户数据**(实测 5 台服务器 + 凭据 + 观看记录),
       且用户可能还要回退去用旧版。替别的应用删用户数据是越权:清缓存可以,清数据不行。 */
    for b in [&local_base, &cache_base].into_iter().flatten() {
        let fl = b.join("LinPlayer").join("Linplayer");
        for n in ["persistent_image_cache", "video_stream_cache"] {
            let _ = std::fs::remove_dir_all(fl.join(n));
        }
        // 只剩空壳就收掉;里面还有别的(用户数据)就自然失败,留着让用户自己看见。
        let _ = std::fs::remove_dir(&fl);
    }

    // 值钱的:用户配置 / 观看记录 / 用户上传的服务器图标 / 已装插件。丢了没法重建。
    if let Some(o) = &old_roaming {
        move_item(&o.join("config.json"), &root.join("config.json"));
        move_item(&o.join("translation.json"), &root.join("translation.json"));
        move_item(&o.join("watch_history.json"), &data.join("watch_history.json"));
        move_item(&o.join("icons"), &cache.join("icons"));
    }
    // whisper 模型几百 MB~几 GB,重下要一晚上 —— 必须搬,不能当缓存删。
    if let Some(o) = &old_data {
        move_item(&o.join("whisper_models"), &data.join("whisper-models"));
        move_item(&o.join("bin"), &data.join("bin"));
    }
    /* identifier 命名的根有**两个**:插件在 Roaming 的(app_config_dir),
       WebView2 profile 在 Local 的(实测 %LOCALAPPDATA%\com.linplayer.poc\EBWebView, 126MB)。
       只处理一个就会漏掉大头。 */
    // 历史 identifier。2026-07-20 已改回 xyz.linplayer.app,但老版本留下的根仍要按旧名清。
    const ID: &str = "com.linplayer.poc";
    if let Some(c) = &roaming_base {
        move_item(&c.join(ID).join("plugins_root"), &data.join("plugins"));
    }
    /* EBWebView **不搬只删**:它 126MB 且多半跨盘(系统盘 → 解压目录可能在别的盘),
       启动时复制会把 App 卡死好几秒。代价是前端 localStorage(弹幕显示设置/搜索历史)
       回到默认 —— 都是点两下就能设回来的显示项,不是账号数据。
       留着不管才是最糟的:用户删了解压目录,系统里还烂着 126MB。 */
    for b in [&roaming_base, &cache_base, &data_base].into_iter().flatten() {
        let _ = std::fs::remove_dir_all(b.join(ID).join("EBWebView"));
    }

    /* 可重建的旧缓存:直接删,不搬 —— 搬只是给自己加风险,而留着就是用户说的"乱拉"残留。
       列**确切名字**而不是把旧根整个 rm -rf:Windows 上 `dirs::cache_dir()/LinPlayer`
       **就是新根本身**(%LOCALAPPDATA%\LinPlayer),盲删等于把刚建好的 data/ 一起端走。 */
    const OURS: [&str; 4] = ["cache", "data", "logs", "downloads"];
    for (base, names) in [
        (&old_roaming, &["danmaku_cache", "ranking_cache", "shaders", "icon_library.json", "bangumi_broadcast.json"][..]),
        (&old_cache, &["images", "shader-cache", "translated_subtitles"][..]),
    ] {
        let Some(b) = base else { continue };
        for n in names {
            let p = b.join(n);
            // 兜底:旧根==新根时,任何撞上我们新目录名的都不许删(现在的名单没撞,防的是以后有人往名单里加)。
            if p.starts_with(root) && OURS.contains(n) {
                continue;
            }
            let _ = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
        }
    }

    // 旧版直接丢在 %TEMP% 根(连子目录都没有)的三个散文件。
    let t = std::env::temp_dir();
    for n in ["linplayer_mpv.log", "linplayer_poc.log", "linplayer_scheme.reg"] {
        let _ = std::fs::remove_file(t.join(n));
    }

    /* 旧根空了就收掉,别在 %APPDATA% 里留个空壳。
       remove_dir 只对**空**目录成功 —— 里面还有没认出来的东西就自然失败,不会误删。
       这也是为什么不用 remove_dir_all:认不出的文件宁可留着让用户看见,也不能替他删。 */
    // identifier 根在 Roaming 和 Local 各有一个,两个都要收。
    let ids: Vec<PathBuf> = [&roaming_base, &cache_base, &data_base]
        .into_iter()
        .flatten()
        .map(|d| d.join(ID))
        .collect();
    for o in [old_roaming, old_cache, old_data].into_iter().flatten().chain(ids) {
        if o.as_path() != root {
            let _ = std::fs::remove_dir(&o);
        }
    }
}

/// 搬一个文件/目录。新的已存在 → 不动(新数据优先);旧的不存在 → 无事发生。
/// 同盘 rename 是原子的;跨盘会失败,故回退到复制+删原件。
fn move_item(from: &Path, to: &Path) {
    if from == to || !from.exists() || to.exists() {
        return;
    }
    if let Some(p) = to.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    if std::fs::rename(from, to).is_ok() {
        return;
    }
    if from.is_dir() {
        if copy_dir(from, to).is_ok() {
            let _ = std::fs::remove_dir_all(from);
        }
    } else if std::fs::copy(from, to).is_ok() {
        let _ = std::fs::remove_file(from);
    }
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)?.flatten() {
        let (s, d) = (e.path(), to.join(e.file_name()));
        if e.file_type()?.is_dir() {
            copy_dir(&s, &d)?;
        } else {
            std::fs::copy(&s, &d)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 每个用例一个独立沙盒根:ROOT 是进程级 OnceLock,测试间会串台,所以这里
    /// **不碰 root()**,只测那些接受显式路径的纯函数。
    fn sandbox(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("lp_paths_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    /// ★ 迁移绝不能覆盖新数据。用户在新根登录过了,旧根还留着上个版本的 config ——
    /// 搬过去就是把新 token 冲掉,表现为"升级后掉登录"。
    #[test]
    fn move_item_never_clobbers_existing_new_data() {
        let s = sandbox("clobber");
        let (old, new) = (s.join("old.json"), s.join("new.json"));
        std::fs::write(&old, b"OLD").unwrap();
        std::fs::write(&new, b"NEW").unwrap();
        move_item(&old, &new);
        assert_eq!(std::fs::read(&new).unwrap(), b"NEW", "新数据被旧的覆盖了");
        assert!(old.exists(), "没搬成就不该把旧的删掉");
    }

    #[test]
    fn move_item_moves_file_and_dir_then_removes_source() {
        let s = sandbox("move");
        let old = s.join("icons");
        std::fs::create_dir_all(old.join("sub")).unwrap();
        std::fs::write(old.join("sub").join("a.png"), b"IMG").unwrap();
        let new = s.join("cache").join("icons");
        move_item(&old, &new);
        assert!(!old.exists(), "旧目录必须搬走而不是复制一份留着");
        assert_eq!(std::fs::read(new.join("sub").join("a.png")).unwrap(), b"IMG");
    }

    #[test]
    fn move_item_is_noop_when_source_missing() {
        let s = sandbox("missing");
        move_item(&s.join("nope"), &s.join("dst"));
        assert!(!s.join("dst").exists(), "源都不存在,不该凭空建出目标");
    }

    /// 造一套「旧版本装机后」的目录:6 个根散落的样子。返回 (roaming, cache, data)。
    fn legacy_tree(s: &Path) -> (PathBuf, PathBuf, PathBuf) {
        let (roaming, cache, data) = (s.join("Roaming"), s.join("Local"), s.join("Roaming"));
        let lp = roaming.join("LinPlayer");
        std::fs::create_dir_all(&lp).unwrap();
        std::fs::write(lp.join("config.json"), b"{\"accounts\":[\"MINE\"]}").unwrap();
        std::fs::write(lp.join("watch_history.json"), b"HISTORY").unwrap();
        std::fs::create_dir_all(lp.join("icons")).unwrap();
        std::fs::write(lp.join("icons").join("srv.png"), b"ICON").unwrap();
        // 可重建的旧缓存
        std::fs::create_dir_all(lp.join("danmaku_cache")).unwrap();
        std::fs::write(lp.join("danmaku_cache").join("x"), b"DM").unwrap();
        std::fs::write(lp.join("icon_library.json"), b"LIB").unwrap();
        // 贵的:模型
        std::fs::create_dir_all(lp.join("whisper_models")).unwrap();
        std::fs::write(lp.join("whisper_models").join("m.bin"), b"MODEL").unwrap();
        // 按 Tauri identifier 命名的根:插件在 Roaming 侧
        let pl = roaming.join("com.linplayer.poc").join("plugins_root");
        std::fs::create_dir_all(&pl).unwrap();
        std::fs::write(pl.join("p.js"), b"PLUGIN").unwrap();
        // Local 根
        let lc = cache.join("LinPlayer");
        std::fs::create_dir_all(lc.join("images")).unwrap();
        std::fs::write(lc.join("images").join("a.jpg"), b"IMG").unwrap();
        // WebView2 profile:Local 侧的 identifier 根,实测 126MB,不是我们的代码写的
        let eb = cache.join("com.linplayer.poc").join("EBWebView");
        std::fs::create_dir_all(eb.join("Default")).unwrap();
        std::fs::write(eb.join("Default").join("huge"), vec![0u8; 4096]).unwrap();
        (roaming, cache, data)
    }

    /// ★★ 这条守的是全项目最贵的一次回归:**升级后账号还在不在**。
    /// config.json 里是登录令牌,搬丢了用户打开就是"服务器全没了",且不报错。
    #[test]
    fn migration_moves_precious_data_and_drops_rebuildable_cache() {
        let s = sandbox("mig_full");
        let (roaming, cache, data) = legacy_tree(&s);
        let root = s.join("NewRoot");

        migrate_from(&root, Some(roaming.clone()), Some(cache.clone()), Some(data), None);

        // 值钱的必须一个不少地到位
        assert_eq!(std::fs::read(root.join("config.json")).unwrap(), b"{\"accounts\":[\"MINE\"]}", "账号配置没搬过来 = 用户升级即掉登录");
        assert_eq!(std::fs::read(root.join("data").join("watch_history.json")).unwrap(), b"HISTORY", "观看记录丢了");
        assert_eq!(std::fs::read(root.join("cache").join("icons").join("srv.png")).unwrap(), b"ICON", "用户上传的服务器图标丢了");
        assert_eq!(std::fs::read(root.join("data").join("plugins").join("p.js")).unwrap(), b"PLUGIN", "已装插件丢了");
        assert_eq!(std::fs::read(root.join("data").join("whisper-models").join("m.bin")).unwrap(), b"MODEL", "几 GB 的模型被当缓存删了");

        // 可重建的旧缓存:必须从旧根清掉,不许烂在磁盘上(这就是用户说的"乱拉")
        assert!(!roaming.join("LinPlayer").join("danmaku_cache").exists(), "旧弹幕缓存没清");
        assert!(!roaming.join("LinPlayer").join("icon_library.json").exists(), "旧图标库缓存没清");
        assert!(!cache.join("LinPlayer").join("images").exists(), "旧封面缓存没清");

        /* ★ WebView2 profile(126MB)必须清掉。它不是我们代码写的 —— 光收拢自家 dirs:: 调用
           管不到它,而压缩包分发下它留在系统里就是"删了文件夹还烂着 126MB"。 */
        assert!(!cache.join("com.linplayer.poc").join("EBWebView").exists(), "WebView2 profile(126MB)没清,删了包还烂在系统里");

        // 旧根搬空后应当被收掉,别在 AppData 里留空壳
        assert!(!roaming.join("LinPlayer").exists(), "旧根搬空了却没收掉");
        assert!(!roaming.join("com.linplayer.poc").exists(), "Roaming 侧 identifier 根没收掉");
        assert!(!cache.join("com.linplayer.poc").exists(), "Local 侧 identifier 根没收掉");
    }

    /// 幂等:第二次跑(每次启动都会跑)不能把已经在用的新数据搞坏。
    #[test]
    fn migration_is_idempotent_and_second_run_keeps_new_data() {
        let s = sandbox("mig_idem");
        let (roaming, cache, data) = legacy_tree(&s);
        let root = s.join("NewRoot");
        migrate_from(&root, Some(roaming.clone()), Some(cache.clone()), Some(data.clone()), None);

        // 用户在新根里又登了一个新账号
        std::fs::write(root.join("config.json"), b"NEWER").unwrap();
        // 旧根又冒出一个 config(比如用户回滚跑了次旧版)
        std::fs::create_dir_all(roaming.join("LinPlayer")).unwrap();
        std::fs::write(roaming.join("LinPlayer").join("config.json"), b"STALE").unwrap();

        migrate_from(&root, Some(roaming), Some(cache), Some(data), None);
        assert_eq!(std::fs::read(root.join("config.json")).unwrap(), b"NEWER", "第二次迁移把用户正在用的新配置覆盖了");
    }

    /// ★★ 真实事故的回归:重构中途有一版把根定在系统本地目录,**把开发者两个带 token 的真账号
    /// 搬了过去**。改成"exe 同级 userdata"后,那份 config 就成了孤儿 —— 新根里生成一个空 config,
    /// 用户打开发现服务器全没了,而数据其实还好端端躺在 %LOCALAPPDATA%\LinPlayer 里。
    ///
    /// 同一条路径也覆盖 SystemFallback→Portable 的正常回流:
    /// 用户先在 Program Files 里跑(数据被迫落系统目录),再把整个包挪到 D 盘,数据必须跟回来。
    #[test]
    fn migration_reclaims_data_from_previous_system_root() {
        let s = sandbox("mig_prev");
        let local = s.join("Local");
        let prev = local.join("LinPlayer"); // 上一版的根,已经是新布局
        std::fs::create_dir_all(prev.join("data")).unwrap();
        std::fs::create_dir_all(prev.join("cache").join("icons")).unwrap();
        std::fs::write(prev.join("config.json"), b"{\"accounts\":[\"REAL_TOKEN\"]}").unwrap();
        std::fs::write(prev.join("data").join("watch_history.json"), b"HISTORY").unwrap();
        std::fs::create_dir_all(prev.join("data").join("plugins")).unwrap();
        std::fs::write(prev.join("data").join("plugins").join("p.js"), b"PLUGIN").unwrap();
        std::fs::write(prev.join("cache").join("icons").join("srv.png"), b"ICON").unwrap();

        let root = s.join("Pkg").join("userdata"); // exe 同级
        migrate_from(&root, None, None, None, Some(local));

        assert_eq!(std::fs::read(root.join("config.json")).unwrap(), b"{\"accounts\":[\"REAL_TOKEN\"]}", "上一版系统根里的真账号没接回包里 = 用户打开就是服务器全没了");
        assert_eq!(std::fs::read(root.join("data").join("watch_history.json")).unwrap(), b"HISTORY", "观看记录没接回来");
        assert_eq!(std::fs::read(root.join("data").join("plugins").join("p.js")).unwrap(), b"PLUGIN", "插件没接回来");
        assert_eq!(std::fs::read(root.join("cache").join("icons").join("srv.png")).unwrap(), b"ICON", "用户上传的图标没接回来");
        assert!(!prev.exists(), "接回来之后旧根该收掉,别在系统里留残留");
    }

    /// ★ Windows 上 `dirs::cache_dir()/LinPlayer` **就是新根本身**(%LOCALAPPDATA%\LinPlayer)。
    /// 迁移里任何"把旧根删掉"的动作都可能把刚建好的 data/ 一起端走 —— 那是删用户数据。
    #[test]
    fn migration_survives_legacy_cache_root_being_the_new_root() {
        let s = sandbox("mig_same");
        let root = s.join("Local").join("LinPlayer"); // == cache_base/LinPlayer
        let cache_base = s.join("Local");
        // 新根里已经有正经数据了
        std::fs::create_dir_all(root.join("data")).unwrap();
        std::fs::write(root.join("data").join("watch_history.json"), b"KEEP").unwrap();
        // 同一个目录下还躺着旧版的 images/ 缓存
        std::fs::create_dir_all(root.join("images")).unwrap();
        std::fs::write(root.join("images").join("a.jpg"), b"IMG").unwrap();

        migrate_from(&root, None, Some(cache_base), None, None);

        assert_eq!(std::fs::read(root.join("data").join("watch_history.json")).unwrap(), b"KEEP", "旧根==新根时把新数据删了");
        assert!(root.exists(), "新根被当成旧根收掉了");
        assert!(!root.join("images").exists(), "旧缓存该清掉");
    }

    /// ★ 老 Flutter 桌面版遗留:**清缓存,但绝不碰它的用户数据**。
    /// 那 60MB 是封面缓存(能重建,该清);同目录树里的 flutter_secure_storage.dat /
    /// shared_preferences.json(实测装着 5 台服务器 + 凭据)是**另一个应用的用户数据** ——
    /// 用户可能还要回退去用旧版,替它删数据是越权。这条钉的就是这条界线。
    #[test]
    fn old_flutter_caches_are_purged_but_its_user_data_is_never_touched() {
        let s = sandbox("flutter");
        let local = s.join("Local");
        let roaming = s.join("Roaming");
        // Local 侧:纯缓存(实测 60MB 的那个)
        let lf = local.join("LinPlayer").join("Linplayer");
        std::fs::create_dir_all(lf.join("persistent_image_cache")).unwrap();
        std::fs::write(lf.join("persistent_image_cache").join("a"), vec![0u8; 512]).unwrap();
        std::fs::create_dir_all(lf.join("video_stream_cache")).unwrap();
        // Roaming 侧:用户数据 —— 一个字节都不许动
        let rf = roaming.join("LinPlayer").join("Linplayer");
        std::fs::create_dir_all(&rf).unwrap();
        std::fs::write(rf.join("flutter_secure_storage.dat"), b"CREDS").unwrap();
        std::fs::write(rf.join("shared_preferences.json"), b"{\"servers\":5}").unwrap();
        std::fs::write(rf.join("watch_history.json"), b"HISTORY").unwrap();

        migrate_from(&s.join("Pkg").join("userdata"), Some(roaming), None, None, Some(local));

        assert!(!lf.join("persistent_image_cache").exists(), "老 Flutter 的 60MB 封面缓存该清掉");
        assert!(!lf.join("video_stream_cache").exists(), "老 Flutter 的视频流缓存该清掉");
        assert_eq!(std::fs::read(rf.join("flutter_secure_storage.dat")).unwrap(), b"CREDS", "把别的应用的凭据删了 = 越权");
        assert_eq!(std::fs::read(rf.join("shared_preferences.json")).unwrap(), b"{\"servers\":5}", "把别的应用的服务器配置删了 = 越权");
        assert_eq!(std::fs::read(rf.join("watch_history.json")).unwrap(), b"HISTORY", "把别的应用的观看记录删了 = 越权");
    }

    #[test]
    fn dir_size_sums_recursively() {
        let s = sandbox("size");
        std::fs::create_dir_all(s.join("a")).unwrap();
        std::fs::write(s.join("a").join("f1"), vec![0u8; 100]).unwrap();
        std::fs::write(s.join("f2"), vec![0u8; 23]).unwrap();
        assert_eq!(dir_size(&s), 123);
        assert_eq!(dir_size(&s.join("nope")), 0, "目录不存在应为 0 而不是 panic");
    }
}
