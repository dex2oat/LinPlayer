use std::path::Path;

fn main() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    /* ★ libmpv 的链接/DLL 拷贝已搬到 crates/mpv/build.rs ——
       `#[link(name = "mpv")]` 在那个 crate 里,link-search 就得由它自己发。
       留在这里的话,任何**不**依赖 apps/desktop 的包(比如 apps/android)在 Windows 上
       一链接就是 LNK1181 找不到 mpv.lib。 */

    /* Linux:把 $ORIGIN 写进 rpath,让**可执行文件同级目录**优先于系统库。
       这是绿色包分发在 Linux 上的等价物:包里放一份 libmpv.so.2 就能自带一个已知可用的
       版本,而不必要求用户去装、也不必污染系统目录。同级没有就照常回落系统库。
       ⚠️ 这里不能走 shell,所以 $ORIGIN 是原样传给链接器的字面量,不是变量展开。 */
    if target_os == "linux" {
        println!("cargo:rustc-link-arg-bins=-Wl,-rpath,$ORIGIN");
    }

    /* ★ 双显卡笔记本:把本进程钉到**独显**上。
       实测(2026-07-15,用户真机 Intel UHD + RTX 5060 Laptop):mpv 日志里
       `Device Name: Intel(R) UHD Graphics` —— Anime4K 整条 CNN 链跑在**核显**上,
       5060 全程没参与,于是「5060 超分卡」。原因是 D3D11 默认适配器在混合显卡本上
       是接显示器的那块(核显),而 LinPlayer.exe 是个新面孔,NVIDIA 驱动的程序配置库里
       没有它 → 落到默认的「集显」档。
       这两个导出符号是 NVIDIA Optimus / AMD Enduro **官方的**进程级切卡开关,
       驱动在加载时读主 exe 的导出表。比硬编码 `d3d11-adapter=NVIDIA` 好:
       不认厂商名字、单显卡机器上天然是空操作。
       ⚠️ 必须同时有 `#[used]` 的静态量(lib.rs)和这里的 /EXPORT —— Rust exe 默认
       没有导出表,只写 #[no_mangle] 驱动是看不见的,而且**不会报错,只是继续用核显**。
       改动后务必回读 mpv 日志的 `Device Name:` 确认,别默认它生效了。 */
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-arg-bins=/EXPORT:NvOptimusEnablement");
        println!("cargo:rustc-link-arg-bins=/EXPORT:AmdPowerXpressRequestHighPerformance");
    }

    /* Sentry 的 release 名要和 pack-portable.ps1 打出的 zip 版本**是同一个数**,
       否则上传的符号/sourcemap 挂在别的 release 上,线上堆栈还是乱码。那个脚本读的是
       tauri.conf.json 的 version,所以这里也读它 —— CARGO_PKG_VERSION 读的是 Cargo.toml,
       两者没有任何机制保证同步(现在都是 0.1.0 纯属巧合)。 */
    let conf_path = Path::new(manifest).join("tauri.conf.json");
    let conf: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&conf_path).expect("read tauri.conf.json"))
            .expect("parse tauri.conf.json");
    let version = conf["version"].as_str().expect("tauri.conf.json 缺 version");
    println!("cargo:rustc-env=LP_VERSION={version}");
    println!("cargo:rerun-if-changed=tauri.conf.json");

    tauri_build::build();
}
