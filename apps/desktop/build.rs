use std::path::Path;

fn main() {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let libdir = Path::new(manifest).join("libmpv");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    /* 链接 libmpv。两端拿库的方式不一样:
       - Windows:仓库里自带导入库 libmpv/mpv.lib,运行时找同目录的 libmpv-2.dll。
       - Linux:链系统的 libmpv.so(构建机装 libmpv-dev)。**不把 .lib 那条 link-search
         也发出去** —— 那个目录里全是 Windows 产物,加进搜索路径只会让链接器在里面
         白翻一遍,真出问题时还多一条误导性的线索。 */
    if target_os == "windows" {
        println!("cargo:rustc-link-search=native={}", libdir.display());
        println!("cargo:rustc-link-lib=dylib=mpv");
    }
    /* ★ 非 Windows **故意不发 link-lib**:那边 libmpv 是运行时 dlopen 的
       (见 src/mpv.rs 的 `mod ffi`)。发了的话就又把 libmpv.so 变成链接期硬依赖 ——
       构建机得装 libmpv-dev,而且 ELF 里会留下一条写死的 DT_NEEDED soname,
       dlopen 那套「一个包适配所有发行版」的意义当场归零。 */

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

    /* 把 libmpv-2.dll 拷到产物目录(target/<profile>/),让 exe 运行时能找到。
       ★ 这是 DLL 进发行包的**唯一**机制,打包脚本和 CI 都从 target/<profile>/ 取它。
         tauri.conf.json 里原先还挂着 `"resources": ["libmpv/libmpv-2.dll"]` —— 那是条
         死配置(bundle.active=false 根本不走 bundler),但 tauri_build **仍然会校验
         resources 路径是否存在**,于是在没有该 DLL 的 Linux 构建机上直接把 build.rs
         干失败:`resource path libmpv/libmpv-2.dll doesn't exist`。已删,别照着
         bundler 文档再加回来。
       Linux 上没有这个文件,整块跳过。 */
    if target_os == "windows" {
        if let Ok(out) = std::env::var("OUT_DIR") {
            // OUT_DIR = target/<profile>/build/<pkg>/out  -> 上溯 3 层到 target/<profile>
            if let Some(profile_dir) = Path::new(&out).ancestors().nth(3) {
                let src = libdir.join("libmpv-2.dll");
                let dst = profile_dir.join("libmpv-2.dll");
                let _ = std::fs::copy(&src, &dst);
            }
        }
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
