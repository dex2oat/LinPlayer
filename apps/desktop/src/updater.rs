/* 应用内更新的「落地」半边:把下好的 zip 覆盖到安装目录,再把自己重新拉起来。
   (检查/下载/校验在平台无关的 linplayer_core::update 里,那边能跑单测;
    这边是必须在真实进程里才成立的部分。)

   ★ 核心难点:**不能覆盖正在运行的自己**。Windows 上 LinPlayer.exe 和已加载的
   libmpv-2.dll 都被锁着,主进程活着就写不进去。

   做法:把自己复制一份到 userdata/temp/lp-updater.exe,带 `--lp-apply-update` 参数
   拉起来,然后主进程退出。那个副本不在被覆盖的文件之列,可以从容地等锁释放、
   覆盖、再把新的 LinPlayer.exe 拉起来。

   为什么不照抄 Flutter 侧那套:那边是往 %TEMP% 写一个 PowerShell 脚本再 detach 执行
   (lib/core/services/update/windows_self_updater.dart)。它得处理 PS 5.1 把
   UTF-8-无 BOM 当 GBK 解码导致中文注释毁掉引号、整个脚本解析失败的坑 —— 那边专门
   写了 BOM 才绕过去。用我们自己的 exe 当 applier 没有编码这一层,代码也更少。

   ★ 这个文件里**一律不许用 paths::*`**。paths::root() 是从 current_exe() 推的,
     而 applier 跑在 <安装目录>/userdata/temp/ 下,推出来的根是错的
     (会变成 .../userdata/temp/userdata)。安装目录一律由命令行参数传进来。 */

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const FLAG: &str = "--lp-apply-update";
/// 等主进程放开 LinPlayer.exe / libmpv-2.dll 的锁。给足时间:用户机器上
/// 杀毒软件扫一遍新落盘的 exe 要好几秒。
const UNLOCK_TIMEOUT: Duration = Duration::from_secs(90);

/// 如果本次启动是「以 applier 身份运行」,就干完活并返回 true(调用方应立即返回,
/// **不要**继续启动 App)。必须在 `run()` 的最开头调用 —— 排在 redirect_process_dirs()
/// 之后就晚了,那一步会按错误的根目录改写 TEMP。
pub fn run_applier_if_requested() -> bool {
    let args: Vec<String> = std::env::args().collect();
    let Some(i) = args.iter().position(|a| a == FLAG) else {
        return false;
    };
    let (Some(staging), Some(install)) = (args.get(i + 1), args.get(i + 2)) else {
        return true; // 参数不全:什么也别做,更不能当普通启动继续跑下去
    };
    let (staging, install) = (PathBuf::from(staging), PathBuf::from(install));

    let log = install.join("userdata").join("logs").join("update.log");
    let say = |m: &str| {
        let _ = std::fs::create_dir_all(log.parent().unwrap());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&log) {
            use std::io::Write;
            let _ = writeln!(f, "{m}");
        }
    };

    say("---- apply update ----");
    match apply(&staging, &install, &say) {
        Ok(()) => say("OK 覆盖完成"),
        // 失败也要把老版本拉回来 —— 否则用户点了「更新」之后 App 直接人间蒸发。
        Err(e) => say(&format!("FAIL {e}")),
    }

    let exe = install.join(APP_EXE);
    match std::process::Command::new(&exe).current_dir(&install).spawn() {
        Ok(_) => say("OK 已重新启动"),
        Err(e) => say(&format!("FAIL 重新启动失败: {e}")),
    }
    // staging 删不掉(本进程正跑在里面),交给下一次正常启动收尸。
    true
}

fn apply(root: &Path, install: &Path, say: &dyn Fn(&str)) -> Result<(), String> {
    let files = list_files(root)?;
    if files.is_empty() {
        return Err("更新包是空的,不敢覆盖".into());
    }
    /* 先把**所有**文件都等到可写,再开始真正覆盖。
       边等边覆盖的话,exe 换成新版、dll 还卡在旧版就退出 —— 那是个装不上也回不去的
       半吊子状态。要么整套换掉,要么一个都不动。 */
    let deadline = Instant::now() + UNLOCK_TIMEOUT;
    for rel in &files {
        wait_writable(&install.join(rel), deadline)
            .map_err(|e| format!("{} 一直被占用: {e}", rel.display()))?;
    }
    say(&format!("{} 个文件已可写", files.len()));

    for rel in &files {
        let (src, dst) = (root.join(rel), install.join(rel));
        if let Some(p) = dst.parent() {
            std::fs::create_dir_all(p).map_err(|e| format!("建目录失败: {e}"))?;
        }
        /* Unix:先 unlink 再写。往**正在运行**的可执行文件里写会得到 ETXTBSY(os error 26),
           而 unlink 只是断开目录项、老 inode 让还开着它的进程继续用完 —— 这正是 Linux
           上「替换运行中的程序」的标准做法,也是这边不需要 Windows 那套等锁的原因。
           不存在就当没这回事。 */
        #[cfg(unix)]
        let _ = std::fs::remove_file(&dst);
        std::fs::copy(&src, &dst).map_err(|e| format!("覆盖 {} 失败: {e}", rel.display()))?;
    }
    // zip 丢了权限位,主程序必须显式补回可执行位(见 ensure_executable 的说明)。
    ensure_executable(&install.join(APP_EXE));
    Ok(())
}

/// 目标存在就等它能被打开成可写(= 老进程放手了);不存在就是新增文件,直接放行。
fn wait_writable(path: &Path, deadline: Instant) -> Result<(), String> {
    loop {
        if !path.exists() {
            return Ok(());
        }
        match std::fs::OpenOptions::new().write(true).open(path) {
            Ok(_) => return Ok(()),
            Err(e) if Instant::now() >= deadline => return Err(e.to_string()),
            Err(_) => std::thread::sleep(Duration::from_millis(200)),
        }
    }
}

/// 目录里只有一个子目录、且没有平铺文件 → 返回那个子目录。
fn single_dir_child(dir: &Path) -> Option<PathBuf> {
    let entries: Vec<_> = std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).collect();
    let [only] = entries.as_slice() else { return None };
    only.path().is_dir().then(|| only.path())
}

/// 递归列出相对路径。
fn list_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    fn walk(dir: &Path, base: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
        for e in std::fs::read_dir(dir).map_err(|e| format!("读取 {} 失败: {e}", dir.display()))? {
            let p = e.map_err(|e| e.to_string())?.path();
            if p.is_dir() {
                walk(&p, base, out)?;
            } else if let Ok(rel) = p.strip_prefix(base) {
                out.push(rel.to_path_buf());
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(root, root, &mut out)?;
    Ok(out)
}

// ---------------------------------------------------------------------------

/// 安装目录 = exe 所在目录。
pub fn install_dir() -> Result<PathBuf, String> {
    std::env::current_exe()
        .map_err(|e| format!("定位自身失败: {e}"))?
        .parent()
        .map(|p| p.to_path_buf())
        .ok_or_else(|| "定位安装目录失败".into())
}

/// 发行包里主程序的文件名(打包脚本/CI 打出来就叫这个)。
/// Linux 的 ELF 没有扩展名 —— 写死 `.exe` 的话 spawn_applier 会一路走到
/// 「更新包里没有 LinPlayer.exe,不敢安装」,应用内更新在 Linux 上 100% 失败。
#[cfg(windows)]
const APP_EXE: &str = "LinPlayer.exe";
#[cfg(not(windows))]
const APP_EXE: &str = "LinPlayer";

/* Unix:把可执行位补回来。
   ★ 必须有:发行包是 zip,而 `zip` crate 解包**不还原 Unix 权限位**,解出来的主程序
     是 0644。覆盖上去之后用户点了「更新」,下次启动就是 Permission denied ——
     更新看着成功了,App 再也起不来。这是 Linux 端最容易漏、后果最严重的一处。 */
#[cfg(unix)]
fn ensure_executable(p: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if let Ok(md) = std::fs::metadata(p) {
        let mut perm = md.permissions();
        perm.set_mode(perm.mode() | 0o755);
        let _ = std::fs::set_permissions(p, perm);
    }
}
#[cfg(not(unix))]
fn ensure_executable(_p: &Path) {}

fn staging_dir() -> PathBuf {
    linplayer_core::paths::temp_dir().join("update-staging")
}

/// 正常启动时清掉上一次更新留下的解包目录。
/// applier 跑在那个目录里,删不掉自己脚下的地,只能由下一次正常启动收尸。
pub fn cleanup_stale_applier() {
    let _ = std::fs::remove_dir_all(staging_dir());
}

/* 解包,然后**用解包出来的那个新 exe** 当 applier 拉起来;调用方随后立刻退出本进程。

   ★ 这是踩了两个坑之后的形状,两个坑都会让更新 100% 失败,且都不报错:

   坑一:「把自己复制到 temp 当 applier」。
     本 exe 的导入表里有 libmpv-2.dll(mpv.rs:38 的 `#[link(name = "mpv")]`),
     Windows 加载器在 `main` **之前**就要解析它,第一个搜索位置是 exe 自己所在的目录。
     temp 里没有那个 DLL → 进程在跑到第一行代码前就被毙了。现象极具迷惑性:
     进程「起来了」又什么都没干,没日志、没报错、没窗口。
     (实测矩阵:同一 exe 原地跑=进分支,复制到别处跑=不进,debug/release 一致 ——
      变量是副本位置,不是构建配置。)

   坑二:「把副本放进安装目录」——解决了坑一,却撞上更硬的:
     副本同样导入 libmpv-2.dll,于是它**把自己要替换的那个 DLL 锁住了**,
     等到超时也等不到可写。日志原话:「libmpv-2.dll 一直被占用 (os error 32)」。

   解法:applier 就用解包目录里那个**新的** LinPlayer.exe。它加载的是解包目录里
   **新的** libmpv-2.dll,安装目录里那两个文件因此都是自由的。不用额外复制 117MB,
   也不用多打一个 updater 程序 —— 新版本自己把自己装上去。 */
pub fn spawn_applier(zip: &Path) -> Result<(), String> {
    let install = install_dir()?;
    let staging = staging_dir();
    let _ = std::fs::remove_dir_all(&staging);
    linplayer_core::update::extract_zip(zip, &staging)?;
    // 包一般是平铺的;万一哪天打包脚本改成套一层目录,这里自动下潜。
    let root = single_dir_child(&staging).unwrap_or(staging);

    let applier = root.join(APP_EXE);
    if !applier.exists() {
        return Err(format!("更新包里没有 {APP_EXE},不敢安装"));
    }
    // 刚从 zip 解出来,Unix 上没有可执行位 —— 不补的话下一行 spawn 直接 Permission denied。
    ensure_executable(&applier);
    std::process::Command::new(&applier)
        .arg(FLAG)
        .arg(&root)
        .arg(&install)
        .spawn()
        .map_err(|e| format!("启动更新程序失败: {e}"))?;
    // zip 已经解开了,留着白占几百 MB。
    let _ = std::fs::remove_file(zip);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch(p: &Path, body: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    }

    #[test]
    fn lists_files_recursively_as_relative_paths() {
        let t = std::env::temp_dir().join("lp_upd_list");
        let _ = std::fs::remove_dir_all(&t);
        touch(&t.join("LinPlayer.exe"), "a");
        touch(&t.join("sub").join("x.dll"), "b");

        let mut got = list_files(&t).unwrap();
        got.sort();
        assert_eq!(
            got,
            vec![PathBuf::from("LinPlayer.exe"), PathBuf::from("sub").join("x.dll")]
        );
        let _ = std::fs::remove_dir_all(&t);
    }

    /* 「套了一层目录」的包必须自动下潜,平铺的包必须原地不动。
       两个方向都要断言 —— 只测下潜的话,一个把平铺包也误判成要下潜的实现照样绿,
       而那会把 LinPlayer.exe 拷成 install/LinPlayer.exe/... */
    #[test]
    fn descends_only_when_the_zip_wraps_everything_in_one_dir() {
        let t = std::env::temp_dir().join("lp_upd_descend");
        let _ = std::fs::remove_dir_all(&t);

        let wrapped = t.join("wrapped");
        touch(&wrapped.join("LinPlayer").join("LinPlayer.exe"), "a");
        assert_eq!(single_dir_child(&wrapped), Some(wrapped.join("LinPlayer")));

        let flat = t.join("flat");
        touch(&flat.join("LinPlayer.exe"), "a");
        touch(&flat.join("libmpv-2.dll"), "b");
        assert_eq!(single_dir_child(&flat), None, "平铺包不该被下潜");

        let _ = std::fs::remove_dir_all(&t);
    }

    /// 不带 flag 的普通启动绝不能被当成 applier —— 那样 App 永远起不来。
    #[test]
    fn normal_launch_is_not_treated_as_applier() {
        assert!(!std::env::args().any(|a| a == FLAG));
        assert!(!run_applier_if_requested());
    }
}
