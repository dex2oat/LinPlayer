use std::path::Path;

/* libmpv 的链接方式(和 src/lib.rs 的 `mod ffi` 严格对应,改一边必须改另一边):

   Windows —— 链接期绑定。仓库自带导入库 libmpv/mpv.lib,运行时找同目录的 libmpv-2.dll。
   其它平台(Linux / Android)—— **故意什么都不发**:那边是运行时 dlopen。
     发了 link-lib 就把 libmpv 变成链接期硬依赖:构建机得装 libmpv-dev,
     ELF 里还会留一条写死的 DT_NEEDED soname,dlopen 那套「一个包适配所有发行版」
     当场归零。安卓同理 —— 那边 .so 是 CI 现拉进 jniLibs 的,链接期根本没有它。

   ★ 为什么这段在 crates/mpv 而不是 apps/desktop:
     `#[link(name = "mpv")]` 写在**本 crate** 里,link-search 就必须由本 crate 发。
     提取 crate 时我把 mpv.rs 搬走了、这段留在了桌面壳 —— 于是在 Windows 上
     `cargo test -p linplayer-android` 直接 LNK1181「无法打开输入文件 mpv.lib」:
     安卓包的依赖图里没有 apps/desktop,自然拿不到那条搜索路径。
     宿主上编安卓包看着奇怪,但那正是**命令对账单测**跑的地方,不能让它红。 */
fn main() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let libdir = Path::new(manifest).join("libmpv");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    println!("cargo:rerun-if-changed=libmpv");

    if target_os != "windows" {
        return;
    }

    println!("cargo:rustc-link-search=native={}", libdir.display());
    println!("cargo:rustc-link-lib=dylib=mpv");

    /* 把 libmpv-2.dll 拷到产物目录(target/<profile>/),让 exe 运行时能找到。
       ★ 这是 DLL 进发行包的**唯一**机制,打包脚本和 CI 都从 target/<profile>/ 取它。
         tauri.conf.json 里别再加 `"resources": ["libmpv/libmpv-2.dll"]` —— 那是条死配置
         (bundle.active=false 根本不走 bundler),但 tauri_build **仍会校验 resources
         路径存在**,于是在没有该 DLL 的 Linux 构建机上直接把 build.rs 干失败。 */
    if let Ok(out) = std::env::var("OUT_DIR") {
        // OUT_DIR = target/<profile>/build/<pkg>/out  -> 上溯 3 层到 target/<profile>
        if let Some(profile_dir) = Path::new(&out).ancestors().nth(3) {
            let _ = std::fs::copy(libdir.join("libmpv-2.dll"), profile_dir.join("libmpv-2.dll"));
        }
    }
}
